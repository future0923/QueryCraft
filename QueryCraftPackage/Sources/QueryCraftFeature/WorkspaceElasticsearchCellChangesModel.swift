import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceElasticsearchCellChangesModel {
    struct Entry {
        let snapshot: WorkspaceDocumentSnapshot
        var edits: [String: WorkspaceDatabaseDataCell]
        let revision: UUID
        let retainedByteCount: Int
        var prepared: WorkspacePreparedDocumentPartialUpdate?
        var sourceText: String?
        var error: String?
        var isValidating = true
    }

    private(set) var entries: [WorkspaceDocumentReference: Entry] = [:]
    private(set) var order: [WorkspaceDocumentReference] = []
    private(set) var isBlocked = false
    private(set) var isCommitting = false
    @ObservationIgnored private var tasks: [WorkspaceDocumentReference: Task<Void, Never>] = [:]
    @ObservationIgnored private let editor = WorkspaceElasticsearchDocumentCellEditor()
    @ObservationIgnored private let validator = WorkspaceElasticsearchDocumentValidator()

    var hasChanges: Bool { !entries.isEmpty }
    var isValidating: Bool { entries.values.contains { $0.isValidating } }
    var errorMessage: String? { order.compactMap { entries[$0]?.error }.first }
    var retainedFields: [WorkspaceDocumentReference: Set<String>] {
        entries.mapValues { Set($0.edits.keys) }
    }
    var preparedUpdates: [WorkspacePreparedDocumentPartialUpdate]? {
        guard hasChanges, !isValidating, errorMessage == nil else { return nil }
        let result = order.compactMap { entries[$0]?.prepared }
        return result.count == entries.count ? result : nil
    }

    func stage(
        snapshot: WorkspaceDocumentSnapshot,
        edits: [String: WorkspaceDatabaseDataCell],
        prepare: @escaping @MainActor @Sendable (WorkspaceDocumentPartialUpdateDraft) async throws
            -> WorkspacePreparedDocumentPartialUpdate
    ) throws {
        guard !isCommitting, !isBlocked else { throw WorkspaceDocumentEditingError.unavailable }
        let reference = snapshot.reference
        if let entry = entries[reference], entry.edits == edits { return }
        let original = entries[reference]?.snapshot ?? snapshot
        guard !original.isTruncated,
              let sequenceNumber = original.sequenceNumber,
              let primaryTerm = original.primaryTerm
        else { throw WorkspaceDocumentEditingError.missingConcurrencyMetadata }
        if edits.isEmpty {
            tasks.removeValue(forKey: reference)?.cancel()
            entries.removeValue(forKey: reference)
            order.removeAll { $0 == reference }
            return
        }
        // Bound originals plus raw edits; prepared JSON adds only a bounded multiple of this budget.
        let entryBytes = original.sourceJSON.count + edits.reduce(0) { total, field in
            guard case .text(let text) = field.value else { return total + field.key.utf8.count + 4 }
            return total + field.key.utf8.count + text.utf8.count
        }
        let retainedBytes = entries.values.reduce(0) { $0 + $1.retainedByteCount }
            - (entries[reference]?.retainedByteCount ?? 0)
        guard retainedBytes + entryBytes <= 16 * 1_024 * 1_024,
              entries[reference] != nil || entries.count < 500 else {
            throw WorkspaceElasticsearchCellChangesError.capacity
        }
        tasks.removeValue(forKey: reference)?.cancel()
        let revision = UUID()
        if entries[reference] == nil { order.append(reference) }
        entries[reference] = Entry(snapshot: original, edits: edits, revision: revision, retainedByteCount: entryBytes)
        tasks[reference] = Task { @MainActor [editor, validator] in
            do {
                let normalized = try await editor.normalizedEdits(in: original.sourceJSON, edits: edits)
                try Task.checkCancellation()
                guard entries[reference]?.revision == revision else { return }
                if normalized.isEmpty {
                    entries.removeValue(forKey: reference)
                    order.removeAll { $0 == reference }
                    tasks[reference] = nil
                    return
                }
                let source = try await editor.replacingFields(in: original.sourceJSON, edits: normalized)
                let validated = try await validator.validate(source)
                let sourceText = await editor.sourceText(validated)
                let fields = try await editor.changedFieldsJSON(edits: normalized)
                try Task.checkCancellation()
                let draft = WorkspaceDocumentPartialUpdateDraft(
                    reference: reference, sequenceNumber: sequenceNumber, primaryTerm: primaryTerm,
                    sourceJSON: validated, changedFieldsJSON: fields
                )
                let prepared = try await prepare(draft)
                try Task.checkCancellation()
                guard entries[reference]?.revision == revision else { return }
                guard prepared.draft == draft else { throw WorkspaceDocumentEditingError.unavailable }
                entries[reference]?.prepared = prepared
                entries[reference]?.edits = normalized
                entries[reference]?.sourceText = sourceText
                entries[reference]?.isValidating = false
                tasks[reference] = nil
            } catch is CancellationError {
                guard entries[reference]?.revision == revision else { return }
                entries[reference]?.error = AppCopy.current.text("校验已取消，请重新编辑或放弃更改。", "Validation was cancelled. Edit again or discard changes.")
                entries[reference]?.isValidating = false
                tasks[reference] = nil
            } catch {
                guard entries[reference]?.revision == revision else { return }
                entries[reference]?.error = error.localizedDescription
                entries[reference]?.isValidating = false
                tasks[reference] = nil
            }
        }
    }

    func initialValue(snapshot: WorkspaceDocumentSnapshot, fieldName: String) async throws
        -> WorkspaceElasticsearchDocumentCellEditor.InitialValue {
        let entry = entries[snapshot.reference]
        let source = try await editor.replacingFields(
            in: entry?.snapshot.sourceJSON ?? snapshot.sourceJSON,
            edits: entry?.edits ?? [:]
        )
        return try await editor.initialValue(sourceJSON: source, fieldName: fieldName)
    }

    nonisolated static func reference(for update: WorkspaceDatabaseDataCellUpdate) -> WorkspaceDocumentReference? {
        func value(_ name: String) -> String? {
            guard let condition = update.primaryKey.first(where: { $0.columnName == name }),
                  case .text(let value) = condition.value else { return nil }
            return value
        }
        guard let index = value("_index"), let id = value("_id") else { return nil }
        return WorkspaceDocumentReference(index: index, id: id, routing: value("_routing"))
    }

    func beginCommit() { isCommitting = true }

    func commit(
        updates: [WorkspacePreparedDocumentPartialUpdate],
        using commit: @MainActor (WorkspacePreparedDocumentPartialUpdate) async throws
            -> WorkspaceDocumentReplacementResult
    ) async throws {
        guard isCommitting else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        defer { isCommitting = false }
        guard !isBlocked, preparedUpdates == updates else {
            isBlocked = true
            throw WorkspaceDocumentEditingError.unavailable
        }
        do {
            for update in updates {
                try Task.checkCancellation()
                let result = try await commit(update)
                guard result.reference == update.draft.reference else {
                    throw WorkspaceDocumentEditingError.unavailable
                }
                // Remove only acknowledged successes, even if cancellation arrives with the response.
                entries.removeValue(forKey: result.reference)
                order.removeAll { $0 == result.reference }
            }
        } catch {
            isBlocked = true
            throw error
        }
    }

    func waitForValidation() async {
        for task in tasks.values { await task.value }
    }

    func cancelValidation() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func discard() {
        cancelValidation()
        entries.removeAll()
        order.removeAll()
        isBlocked = false
        isCommitting = false
    }
}

private enum WorkspaceElasticsearchCellChangesError: LocalizedError {
    case capacity

    var errorDescription: String? {
        AppCopy.current.text(
            "待修改文档已达到内存上限，请先提交或放弃现有更改。",
            "Pending documents reached the memory limit. Commit or discard existing changes first."
        )
    }
}
