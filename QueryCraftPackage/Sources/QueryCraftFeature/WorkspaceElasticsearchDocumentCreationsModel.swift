import Foundation
import Observation

struct WorkspacePreparedDocumentCreationRow: Equatable, Sendable {
    let rowID: UUID
    let creation: WorkspacePreparedDocumentCreation
}

@MainActor
@Observable
final class WorkspaceElasticsearchDocumentCreationsModel {
    struct Input: Equatable {
        let documentID: String
        let routing: String
        let text: String
    }

    struct Projection: Equatable {
        let drafts: [String: WorkspaceDatabaseDataRowInsertDraft]
    }

    private(set) var entries: [UUID: WorkspaceElasticsearchDocumentInspectorModel] = [:]
    private(set) var order: [UUID] = []
    private(set) var projections: [UUID: Projection] = [:]
    private(set) var transformingRows: Set<UUID> = []
    private(set) var isBlocked = false
    private(set) var isCommitting = false
    private(set) var failedRowID: UUID?
    private(set) var canCorrectDuplicateID = false
    private(set) var mutationRevision = 0
    @ObservationIgnored private var inputs: [UUID: Input] = [:]
    @ObservationIgnored private var baseSources: [UUID: Data] = [:]
    @ObservationIgnored private var revisions: [UUID: UUID] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let editor = WorkspaceElasticsearchDocumentCellEditor()

    var hasChanges: Bool { !order.isEmpty }
    var isValidating: Bool { !transformingRows.isEmpty || entries.values.contains { $0.isValidating } }
    var errorMessage: String? { order.compactMap { entries[$0]?.validationErrorMessage }.first }
    var preparedRows: [WorkspacePreparedDocumentCreationRow]? {
        guard hasChanges, !isValidating, errorMessage == nil else { return nil }
        let rows = order.compactMap { id in
            entries[id]?.preparedCreation.map { WorkspacePreparedDocumentCreationRow(rowID: id, creation: $0) }
        }
        return rows.count == order.count ? rows : nil
    }

    func add(
        rowID: UUID, targetName: String, targetKind: WorkspaceDocumentCreationTargetKind,
        sourceJSON: Data = Data("{}".utf8), routing: String? = nil,
        prepare: @escaping @MainActor @Sendable (WorkspaceDocumentCreationDraft) async throws -> WorkspacePreparedDocumentCreation
    ) throws {
        guard !isCommitting, !isBlocked, entries[rowID] == nil, order.count < 500,
              sourceJSON.count <= WorkspaceElasticsearchDocumentValidator.maximumByteCount,
              retainedBytes(excluding: rowID) + sourceJSON.count <= 16 * 1_024 * 1_024 else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        try model.beginCreating(targetName: targetName, targetKind: targetKind, sourceJSON: sourceJSON,
            routing: routing, prepare: prepare)
        entries[rowID] = model
        order.append(rowID)
        inputs[rowID] = Input(documentID: "", routing: routing ?? "", text: model.draftText)
        baseSources[rowID] = sourceJSON
        mutationRevision &+= 1
    }

    func installPaste(
        _ documents: [WorkspaceElasticsearchPastedDocument],
        prepared: [WorkspacePreparedDocumentCreation],
        replacingEmptyRowID: UUID?
    ) throws {
        guard !isCommitting, !isBlocked, !documents.isEmpty,
              documents.count == prepared.count,
              zip(documents, prepared).allSatisfy({ $0.draft == $1.draft }),
              Set(documents.map { $0.row.id }).count == documents.count,
              documents.allSatisfy({ entries[$0.row.id] == nil || $0.row.id == replacingEmptyRowID }),
              replacingEmptyRowID.map({ isEmptyCreation($0) && documents.first?.row.id == $0 }) ?? true else {
            throw WorkspaceDocumentEditingError.unavailable
        }
        let replacingCount = replacingEmptyRowID == nil ? 0 : 1
        let bytes = documents.reduce(0) { $0 + $1.draft.sourceJSON.count }
        guard order.count - replacingCount + documents.count <= 500,
              retainedBytes(excluding: replacingEmptyRowID ?? UUID()) + bytes <= 16 * 1_024 * 1_024 else {
            throw WorkspaceElasticsearchPasteError.limit
        }
        let insertionIndex = replacingEmptyRowID.flatMap { order.firstIndex(of: $0) } ?? order.count
        if let replacingEmptyRowID { remove(rowIDs: [replacingEmptyRowID]) }
        // Parsing and request preparation finish before this synchronous, atomic state publication.
        for (document, creation) in zip(documents, prepared) {
            let id = document.row.id
            let model = WorkspaceElasticsearchDocumentInspectorModel()
            model.installPastedCreation(creation, sourceText: document.sourceText)
            entries[id] = model
            inputs[id] = Input(documentID: creation.draft.id ?? "", routing: creation.draft.routing ?? "", text: document.sourceText)
            baseSources[id] = creation.draft.sourceJSON
            projections[id] = Projection(drafts: document.row.drafts)
        }
        order.insert(contentsOf: documents.map { $0.row.id }, at: insertionIndex)
        mutationRevision &+= 1
    }

    func isEmptyCreation(_ rowID: UUID) -> Bool {
        guard let input = inputs[rowID] else { return false }
        return input.documentID.isEmpty && input.routing.isEmpty && input.text == "{}"
            && !transformingRows.contains(rowID)
    }

    func updateInspector(
        rowID: UUID, documentID: String, routing: String, text: String, fieldNames: Set<String>,
        prepare: @escaping @MainActor @Sendable (WorkspaceDocumentCreationDraft) async throws -> WorkspacePreparedDocumentCreation
    ) {
        let input = Input(documentID: documentID, routing: routing, text: text)
        guard let model = entries[rowID], !isCommitting, inputs[rowID] != input else { return }
        if isBlocked && !(canCorrectDuplicateID && failedRowID == rowID) { return }
        let changesFailedID = canCorrectDuplicateID && failedRowID == rowID
            && inputs[rowID]?.documentID != documentID
        inputs[rowID] = input
        mutationRevision &+= 1
        guard retainedBytes(excluding: rowID) + text.utf8.count <= 16 * 1_024 * 1_024 else {
            tasks.removeValue(forKey: rowID)?.cancel()
            revisions[rowID] = nil
            transformingRows.remove(rowID)
            model.beginDraftTransformation()
            model.finishDraftTransformationFailure(WorkspaceDocumentEditingError.sourceTooLarge(16 * 1_024 * 1_024))
            return
        }
        model.updateCreationDraft(documentID: documentID, routing: routing, text: text, prepare: prepare)
        let revision = startTransformation(rowID)
        tasks[rowID] = Task { @MainActor [editor] in
            await model.waitForValidation()
            guard !Task.isCancelled, revisions[rowID] == revision else { return }
            do {
                if let creation = model.preparedCreation {
                    let drafts = try await editor.creationDrafts(sourceJSON: creation.draft.sourceJSON, fieldNames: fieldNames)
                    try Task.checkCancellation()
                    guard revisions[rowID] == revision else { return }
                    baseSources[rowID] = creation.draft.sourceJSON
                    projections[rowID] = Projection(drafts: Self.identityDrafts(drafts, input: input))
                    if changesFailedID { isBlocked = false; canCorrectDuplicateID = false; failedRowID = nil }
                }
            } catch is CancellationError {
                return
            } catch {
                guard revisions[rowID] == revision else { return }
                model.finishDraftTransformationFailure(error)
            }
            finishTransformation(rowID, revision: revision)
        }
    }

    func project(rowID: UUID, fieldNames: Set<String>) {
        guard let model = entries[rowID], let input = inputs[rowID] else { return }
        let revision = startTransformation(rowID)
        tasks[rowID] = Task { @MainActor [editor] in
            await model.waitForValidation()
            guard !Task.isCancelled, revisions[rowID] == revision else { return }
            if let source = model.preparedCreation?.draft.sourceJSON,
               let drafts = try? await editor.creationDrafts(sourceJSON: source, fieldNames: fieldNames),
               !Task.isCancelled, revisions[rowID] == revision {
                projections[rowID] = Projection(drafts: Self.identityDrafts(drafts, input: input))
            }
            finishTransformation(rowID, revision: revision)
        }
    }

    func updateGrid(
        row: WorkspaceDatabaseDataRowInsertDraftRow,
        prepare: @escaping @MainActor @Sendable (WorkspaceDocumentCreationDraft) async throws -> WorkspacePreparedDocumentCreation
    ) {
        guard let model = entries[row.id], !isCommitting,
              !isBlocked || (canCorrectDuplicateID && failedRowID == row.id) else { return }
        let documentID = Self.identityValue(row.drafts["_id"])
        mutationRevision &+= 1
        let routing = Self.identityValue(row.drafts["_routing"])
        let changesFailedID = canCorrectDuplicateID && failedRowID == row.id
            && inputs[row.id]?.documentID != documentID
        var edits: [String: WorkspaceDatabaseDataCell] = [:]
        for name in row.editedColumnNames where name != "_id" && name != "_routing" {
            guard let draft = row.drafts[name] else { continue }
            if draft.mode == .null { edits[name] = .null }
            if draft.mode == .value { edits[name] = .text(draft.text) }
        }
        let source = baseSources[row.id] ?? Data("{}".utf8)
        let revision = startTransformation(row.id)
        model.beginDraftTransformation()
        tasks[row.id] = Task { @MainActor [editor] in
            do {
                let source = try await editor.replacingFields(in: source, edits: edits)
                let text = await editor.sourceText(source)
                try Task.checkCancellation()
                guard revisions[row.id] == revision else { return }
                guard retainedBytes(excluding: row.id) + source.count <= 16 * 1_024 * 1_024 else {
                    throw WorkspaceDocumentEditingError.sourceTooLarge(16 * 1_024 * 1_024)
                }
                inputs[row.id] = Input(documentID: documentID, routing: routing, text: text)
                model.updateCreationDraft(documentID: documentID, routing: routing, text: text, prepare: prepare)
                await model.waitForValidation()
                try Task.checkCancellation()
                guard revisions[row.id] == revision else { return }
                if changesFailedID, model.preparedCreation != nil {
                    isBlocked = false; canCorrectDuplicateID = false; failedRowID = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard revisions[row.id] == revision else { return }
                model.finishDraftTransformationFailure(error)
            }
            finishTransformation(row.id, revision: revision)
        }
    }

    func remove(rowIDs: Set<UUID>) {
        guard !isCommitting else { return }
        mutationRevision &+= 1
        if canCorrectDuplicateID, let failedRowID, rowIDs.contains(failedRowID) {
            isBlocked = false
            self.failedRowID = nil
            canCorrectDuplicateID = false
        }
        for id in rowIDs {
            tasks.removeValue(forKey: id)?.cancel()
            revisions[id] = nil
            transformingRows.remove(id)
            entries.removeValue(forKey: id)?.discardChanges()
            inputs[id] = nil
            baseSources[id] = nil
            projections[id] = nil
        }
        order.removeAll { rowIDs.contains($0) }
        if order.isEmpty { isBlocked = false; failedRowID = nil; canCorrectDuplicateID = false }
    }

    func beginCommit() {
        isCommitting = true
        for model in entries.values { _ = model.beginCommit() }
    }

    func commit(
        rows: [WorkspacePreparedDocumentCreationRow],
        using commit: @MainActor (WorkspacePreparedDocumentCreation) async throws -> WorkspaceDocumentCreationResult
    ) async throws -> [WorkspaceDocumentCreationResult] {
        guard isCommitting else { throw WorkspaceDocumentEditingError.unavailable }
        defer { isCommitting = false }
        guard !isBlocked, preparedRows == rows else { throw WorkspaceDocumentEditingError.unavailable }
        var results: [WorkspaceDocumentCreationResult] = []
        for row in rows {
            do {
                try Task.checkCancellation()
                let result = try await commit(row.creation)
                guard row.creation.draft.id == nil || result.reference.id == row.creation.draft.id,
                      result.reference.routing == row.creation.draft.routing,
                      !result.reference.index.isEmpty else { throw WorkspaceDocumentEditingError.unavailable }
                results.append(result)
                // Never resend an acknowledged auto-ID creation, even when cancellation arrives with its response.
                entries.removeValue(forKey: row.rowID)?.discardChanges()
                order.removeAll { $0 == row.rowID }
                inputs[row.rowID] = nil
                baseSources[row.rowID] = nil
                projections[row.rowID] = nil
            } catch {
                for model in entries.values { model.finishCommitFailure(CancellationError()) }
                isBlocked = true
                failedRowID = row.rowID
                canCorrectDuplicateID = (error as? WorkspaceDocumentEditingError) == .documentAlreadyExists
                throw error
            }
        }
        return results
    }

    func waitForValidation() async {
        for task in tasks.values { await task.value }
        for model in entries.values { await model.waitForValidation() }
    }

    func cancelTasks() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        revisions.removeAll()
        transformingRows.removeAll()
        for model in entries.values { model.cancelDraftValidation() }
    }

    func discard() {
        cancelTasks()
        isCommitting = false
        remove(rowIDs: Set(order))
    }

    private func startTransformation(_ rowID: UUID) -> UUID {
        tasks.removeValue(forKey: rowID)?.cancel()
        let revision = UUID()
        revisions[rowID] = revision
        transformingRows.insert(rowID)
        return revision
    }

    private func retainedBytes(excluding rowID: UUID) -> Int {
        inputs.reduce(0) { $0 + ($1.key == rowID ? 0 : $1.value.text.utf8.count) }
    }

    private func finishTransformation(_ rowID: UUID, revision: UUID) {
        guard revisions[rowID] == revision else { return }
        tasks[rowID] = nil
        transformingRows.remove(rowID)
    }

    private static func identityValue(_ draft: WorkspaceDatabaseDataRowInsertDraft?) -> String {
        draft?.mode == .value ? draft?.text ?? "" : ""
    }

    private static func identityDrafts(_ drafts: [String: WorkspaceDatabaseDataRowInsertDraft], input: Input)
        -> [String: WorkspaceDatabaseDataRowInsertDraft] {
        var result = drafts
        if !input.documentID.isEmpty { result["_id"] = .init(mode: .value, text: input.documentID) }
        if !input.routing.isEmpty { result["_routing"] = .init(mode: .value, text: input.routing) }
        return result
    }
}
