import Foundation
import CoreFoundation
import Observation

struct WorkspaceMappingEditorRow: Identifiable, Equatable, Sendable {
    var id: UUID
    let originalPath: [String]?
    var parentPath: [String]
    var container: String
    var name: String
    var type: String
    var parameters: [String: String]
    let hasConflict: Bool
    var isNew: Bool { originalPath == nil }
    var path: [String] { parentPath + [container, name] }
    var displayPath: String { path.enumerated().filter { $0.offset % 2 == 1 }.map(\.element).joined(separator: ".") }
    var editableParameters: [String] { WorkspaceMappingCodec.editableParameters(type: type, isNew: isNew) }
}

actor WorkspaceMappingEditorWorker {
    func presentation(rows: [WorkspaceMappingEditorRow], originals: [WorkspaceMappingEditorRow], capabilities: [WorkspaceDocumentMappingField]) throws -> WorkspaceMappingGridPresentation {
        let names = [AppCopy.current.text("字段", "Field"), AppCopy.current.text("类型", "Type"), AppCopy.current.text("已索引", "Indexed"), AppCopy.current.text("可搜索", "Searchable"), AppCopy.current.text("可聚合", "Aggregatable")]
        let columns = names.enumerated().map { WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element) }
        let caps = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.path, $0) })
        let baseline = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        var changed: [Int: Set<Int>] = [:]
        let values = try rows.enumerated().map { index, row -> WorkspaceDatabaseDataRow in
            try Task.checkCancellation()
            if row != baseline[row.id] { changed[index] = [0, 1, 2] }
            let capability = caps[row.displayPath]
            let pending = AppCopy.current.text("待刷新", "Pending Refresh")
            return .init(id: index, values: [.text(row.displayPath), .text(row.type + (row.hasConflict ? " ⚠" : "")),
                .text(row.parameters["index"] ?? AppCopy.current.text("服务器默认", "Server Default")),
                .text(!row.isNew && capability != nil ? (capability!.isSearchable ? "true" : "false") : pending),
                .text(!row.isNew && capability != nil ? (capability!.isAggregatable ? "true" : "false") : pending)])
        }
        return .init(page: .init(columns: columns, rows: values, offset: 0, limit: max(1, rows.count), hasNextPage: false), changedColumns: changed)
    }

    func rawText(_ snapshot: WorkspaceMappingSnapshot) -> String {
        (try? ElasticsearchJSONWhitespaceFormatter.format(snapshot.rawJSON)) ?? String(decoding: snapshot.rawJSON, as: UTF8.self)
    }
    func responseText(_ response: WorkspaceRequestExecutionResult) -> String {
        "HTTP \(response.statusCode)\n" + String(decoding: response.body, as: UTF8.self)
    }
    func restoredRows(_ snapshot: WorkspaceMappingSnapshot, previous: [WorkspaceMappingEditorRow]) throws -> [WorkspaceMappingEditorRow] {
        var loaded = try rows(snapshot)
        let identities = previous.reduce(into: [[String]: UUID]()) { $0[$1.path] = $1.id }
        for index in loaded.indices {
            if let id = identities[loaded[index].path] { loaded[index].id = id }
        }
        return loaded
    }
    func rows(_ snapshot: WorkspaceMappingSnapshot) throws -> [WorkspaceMappingEditorRow] {
        try snapshot.fields.map { field in
            try Task.checkCancellation()
            let raw = try WorkspaceMappingCodec.object(field.definitionJSON)
            let parameters = raw.reduce(into: [String: String]()) { result, pair in
                if let string = pair.value as? String { result[pair.key] = string }
                else if let number = pair.value as? NSNumber {
                    result[pair.key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
                }
            }
            return WorkspaceMappingEditorRow(id: UUID(), originalPath: field.path, parentPath: Array(field.path.dropLast(2)),
                container: field.path[field.path.count - 2], name: field.name,
                type: raw["type"] as? String ?? "object", parameters: parameters, hasConflict: field.hasConflict)
        }
    }

    func draft(snapshot: WorkspaceMappingSnapshot, rows: [WorkspaceMappingEditorRow], originals: [WorkspaceMappingEditorRow]) throws -> WorkspaceMappingDraft {
        var changes: [WorkspaceMappingFieldChange] = []
        let baseline = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, $0) })
        for row in rows {
            try Task.checkCancellation()
            let original = baseline[row.id]
            guard row != original else { continue }
            guard row.isNew || (row.name == original?.name && row.type == original?.type && row.path == original?.path) else { throw WorkspaceMappingError.invalidDraft }
            var definition: [String: Any] = ["type": row.type]
            if let original {
                for key in row.editableParameters where original.parameters[key] != nil && row.parameters[key] == nil {
                    // Removing a configured parameter cannot restore an unspecified server default.
                    throw WorkspaceMappingError.invalidDraft
                }
            }
            for key in row.editableParameters {
                guard let text = row.parameters[key], !text.isEmpty,
                      row.isNew || text != original?.parameters[key] else { continue }
                if ["analyzer", "normalizer", "format"].contains(key) { definition[key] = text }
                else if key == "ignore_above" {
                    guard let value = Int(text), value >= 0 else { throw WorkspaceMappingError.invalidDraft }
                    definition[key] = value
                } else {
                    guard ["true", "false"].contains(text) else { throw WorkspaceMappingError.invalidDraft }
                    definition[key] = text == "true"
                }
            }
            if !row.isNew, definition.count == 1 { continue }
            changes.append(.init(path: row.path, definitionJSON: try WorkspaceMappingCodec.json(definition), isNew: row.isNew))
        }
        return WorkspaceMappingDraft(baseline: snapshot, changes: changes)
    }

    func verify(_ prepared: WorkspacePreparedMappingUpdate, snapshot: WorkspaceMappingSnapshot) throws -> Bool {
        try WorkspaceMappingCodec.containsChanges(prepared.draft, current: snapshot)
    }
}

struct WorkspaceMappingGridPresentation: Sendable {
    let page: WorkspaceDatabaseDataPage
    let changedColumns: [Int: Set<Int>]
}

@MainActor @Observable
final class WorkspaceElasticsearchMappingEditor {
    private(set) var snapshot: WorkspaceMappingSnapshot?
    private(set) var rows: [WorkspaceMappingEditorRow] = []
    private(set) var originals: [WorkspaceMappingEditorRow] = []
    private(set) var prepared: WorkspacePreparedMappingUpdate?
    private(set) var isLoading = false
    private(set) var isCommitting = false
    private(set) var isBlocked = false
    var errorMessage: String?
    var selectedID: UUID?
    var aliasTarget: String = ""
    var showsUnlockConfirmation = false
    var showsConflictConfirmation = false
    @ObservationIgnored private var pendingEdit: (@MainActor () -> Void)?
    private(set) var aliasTargets: [String] = []
    private(set) var presentation = WorkspaceMappingGridPresentation(page: .init(columns: [
        AppCopy.current.text("字段", "Field"), AppCopy.current.text("类型", "Type"), AppCopy.current.text("已索引", "Indexed"),
        AppCopy.current.text("可搜索", "Searchable"), AppCopy.current.text("可聚合", "Aggregatable")
    ].enumerated().map { .init(id: $0.offset, name: $0.element) }, rows: [], offset: 0, limit: 1, hasNextPage: false), changedColumns: [:])
    private(set) var rawText = ""
    @ObservationIgnored private var baselinePresentation: WorkspaceMappingGridPresentation?
    let lifetime = WorkspaceDataCellEditingLifetime()
    @ObservationIgnored private let worker = WorkspaceMappingEditorWorker()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    var hasChanges: Bool { rows != originals }
    var canCommit: Bool { hasChanges && prepared != nil && !isCommitting && !isBlocked }
    var canAddFields: Bool {
        snapshot != nil && snapshot?.target.kind != .elasticsearchAlias && !isLoading && !isCommitting && !isBlocked
    }
    var selectedRow: WorkspaceMappingEditorRow? { rows.first { $0.id == selectedID } }

    func requestEdit(workspace: WorkspaceModel, action: @escaping @MainActor () -> Void) {
        guard !isCommitting, !isLoading, !isBlocked else { return }
        guard hasChanges || !workspace.elasticsearchHasPendingChanges() else {
            errorMessage = AppCopy.current.text("请先提交或放弃其他待提交更改。", "Commit or discard other pending changes first."); return
        }
        if workspace.safetyLock.isEnabled { pendingEdit = action; showsUnlockConfirmation = true }
        else { action() }
    }

    func confirmUnlock(workspace: WorkspaceModel) {
        workspace.safetyLock.disable(); showsUnlockConfirmation = false
        let action = pendingEdit; pendingEdit = nil; action?()
    }
    func cancelUnlock() { pendingEdit = nil; showsUnlockConfirmation = false }

    func load(target: WorkspaceMappingTarget, workspace: WorkspaceModel) {
        guard !hasChanges, !isCommitting else { return }
        loadTask?.cancel(); prepareTask?.cancel()
        let id = UUID(); revision = id; isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if revision == id { isLoading = false; loadTask = nil } }
            do {
                let fetched = try await workspace.fetchElasticsearchMapping(target)
                let loaded = try await worker.restoredRows(fetched, previous: rows)
                let presentation = try await worker.presentation(rows: loaded, originals: loaded, capabilities: fetched.fieldCapabilities)
                let rawText = await worker.rawText(fetched)
                try Task.checkCancellation()
                guard revision == id else { return }
                snapshot = fetched; rows = loaded; originals = loaded; prepared = nil
                self.presentation = presentation; baselinePresentation = presentation; self.rawText = rawText
                isBlocked = false; errorMessage = nil; showsConflictConfirmation = false
                if !loaded.contains(where: { $0.id == selectedID }) { selectedID = nil }
                if target.kind == .elasticsearchAlias { aliasTargets = fetched.indexMappings.keys.sorted(); aliasTarget = "" }
            } catch is CancellationError {} catch { if revision == id { errorMessage = error.localizedDescription } }
        }
    }

    func add(parent: WorkspaceMappingEditorRow? = nil, multiField: Bool = false, workspace: WorkspaceModel) {
        guard canAddFields else { return }
        let row = WorkspaceMappingEditorRow(id: UUID(), originalPath: nil, parentPath: parent?.path ?? [],
            container: multiField ? "fields" : "properties", name: "", type: multiField ? "keyword" : "text", parameters: [:], hasConflict: false)
        rows.append(row); selectedID = row.id; changed(workspace: workspace)
    }

    func update(_ row: WorkspaceMappingEditorRow, workspace: WorkspaceModel) {
        guard !isLoading, !isCommitting, !isBlocked, snapshot?.target.kind != .elasticsearchAlias,
              !row.hasConflict, !workspace.safetyLock.isEnabled,
              let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let oldPath = rows[index].path
        rows[index] = row
        if row.isNew, oldPath != row.path {
            for child in rows.indices where rows[child].isNew && rows[child].parentPath.starts(with: oldPath) {
                rows[child].parentPath = row.path + rows[child].parentPath.dropFirst(oldPath.count)
            }
        }
        changed(workspace: workspace)
    }

    func removeDraft(_ id: UUID, workspace: WorkspaceModel) {
        guard !isCommitting, let index = rows.firstIndex(where: { $0.id == id && $0.isNew }) else { return }
        let path = rows[index].path
        lifetime.finish(commit: false)
        rows.removeAll { $0.id == id || ($0.isNew && $0.parentPath.starts(with: path)) }
        selectedID = rows.isEmpty ? nil : rows[min(index, rows.count - 1)].id
        changed(workspace: workspace)
    }

    func discard() {
        guard !isCommitting else { return }
        lifetime.finish(commit: false)
        prepareTask?.cancel(); revision = UUID()
        rows = originals; prepared = nil; isBlocked = false; errorMessage = nil; showsConflictConfirmation = false
        if let baselinePresentation { presentation = baselinePresentation }
        if !rows.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }

    private func changed(workspace: WorkspaceModel) {
        revision = UUID(); let id = revision
        prepared = nil; errorMessage = nil; prepareTask?.cancel()
        guard hasChanges, let snapshot else {
            if let baselinePresentation { presentation = baselinePresentation }
            return
        }
        let current = rows; let baseline = originals
        let caps = capabilities(workspace)
        prepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                let presentation = try await worker.presentation(rows: current, originals: baseline, capabilities: caps)
                guard revision == id, !Task.isCancelled else { return }
                self.presentation = presentation
                let draft = try await worker.draft(snapshot: snapshot, rows: current, originals: baseline)
                let result = try await workspace.prepareElasticsearchMapping(draft)
                guard revision == id, !Task.isCancelled else { return }
                prepared = result; prepareTask = nil
            } catch is CancellationError {} catch { if revision == id { errorMessage = error.localizedDescription; prepareTask = nil } }
        }
    }

    func commit(workspace: WorkspaceModel) {
        lifetime.finish(commit: true)
        guard canCommit, let prepared else { return }
        isCommitting = true
        commitTask = Task { [weak self] in
            guard let self else { return }
            defer { isCommitting = false; commitTask = nil }
            do {
                let response = try await workspace.commitElasticsearchMapping(prepared)
                guard (200..<300).contains(response.statusCode) else {
                    errorMessage = await worker.responseText(response)
                    return
                }
                // Own the whole reconciliation, so cancellation cannot discard an acknowledged update.
                let recovery = Task { try await reconcile(prepared, workspace: workspace) }
                try await recovery.value
            } catch {
                errorMessage = error.localizedDescription; isBlocked = true
                if let mappingError = error as? WorkspaceMappingError {
                    switch mappingError {
                    case .conflict:
                        // Present once for this failed submission, not whenever blocked rows change selection.
                        showsConflictConfirmation = true
                        return
                    case .invalidDraft: return
                    case .uncertain: break
                    }
                }
                // Network/stop may have followed a committed update. Never replay it automatically.
                let recovery = Task { try await reconcile(prepared, workspace: workspace) }
                _ = try? await recovery.value
            }
        }
    }

    private func reconcile(_ prepared: WorkspacePreparedMappingUpdate, workspace: WorkspaceModel) async throws {
        let current = try await workspace.fetchElasticsearchMapping(prepared.draft.baseline.target)
        guard try await worker.verify(prepared, snapshot: current) else { throw WorkspaceMappingError.uncertain }
        let loaded = try await worker.restoredRows(current, previous: rows)
        let presentation = try await worker.presentation(rows: loaded, originals: loaded, capabilities: current.fieldCapabilities)
        let rawText = await worker.rawText(current)
        snapshot = current; rows = loaded; originals = loaded; self.prepared = nil
        self.presentation = presentation; baselinePresentation = presentation; self.rawText = rawText
        errorMessage = nil; isBlocked = false; showsConflictConfirmation = false
        if !loaded.contains(where: { $0.id == selectedID }) { selectedID = nil }
        await workspace.didMutateElasticsearchMapping()
    }

    func stop() {
        lifetime.finish(commit: true)
        loadTask?.cancel(); prepareTask?.cancel(); commitTask?.cancel()
    }

    func resumePreparation(workspace: WorkspaceModel) {
        if hasChanges, !isCommitting, !isBlocked, prepared == nil { changed(workspace: workspace) }
    }

    private func capabilities(_ workspace: WorkspaceModel) -> [WorkspaceDocumentMappingField] {
        snapshot?.fieldCapabilities ?? []
    }
}
