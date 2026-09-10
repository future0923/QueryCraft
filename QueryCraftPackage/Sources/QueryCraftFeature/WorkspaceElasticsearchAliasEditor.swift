import Foundation
import Observation

@MainActor @Observable
final class WorkspaceElasticsearchAliasEditor {
    private(set) var snapshot: WorkspaceElasticsearchAliasSnapshot?
    private(set) var rows: [WorkspaceElasticsearchAliasEditorRow] = []
    private(set) var prepared: WorkspacePreparedElasticsearchAliasUpdate?
    private(set) var isLoading = false
    private(set) var isCommitting = false
    private(set) var isBlocked = false
    private(set) var errorMessage: String?
    var showsUnlockConfirmation = false
    var showsAddBinding = false
    var newBindingName = ""
    var newBindingIsWriteIndex = false

    @ObservationIgnored private let worker = WorkspaceElasticsearchAliasWorker()
    @ObservationIgnored private var loadRevision = UUID()
    @ObservationIgnored private var editRevision = UUID()
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAction: (@MainActor () -> Void)?

    var hasChanges: Bool { rows.contains(where: \.isModified) }
    var canEdit: Bool {
        snapshot != nil && !isLoading && !isCommitting && !isBlocked
    }
    var canCommit: Bool {
        hasChanges && prepared != nil && !isCommitting && !isBlocked
    }

    func load(selection: WorkspaceDatabaseObjectSelection, workspace: WorkspaceModel) async {
        guard [.elasticsearchIndex, .elasticsearchAlias].contains(selection.kind),
              !selection.objectName.hasPrefix(".ds-") else {
            clearLoadedState()
            return
        }
        await load {
            try await self.worker.load(selection) { request in
                try await workspace.executeElasticsearchRequest(request)
            }
        }
    }

    func load(fetch: () async throws -> WorkspaceElasticsearchAliasSnapshot) async {
        guard !hasChanges, !isCommitting else { return }
        let revision = UUID()
        loadRevision = revision
        isLoading = true
        defer { if loadRevision == revision { isLoading = false } }
        do {
            let loaded = try await fetch()
            let loadedRows = await worker.rows(loaded, preserving: rows)
            try Task.checkCancellation()
            guard loadRevision == revision, !hasChanges, !isCommitting else { return }
            snapshot = loaded
            rows = loadedRows
            resetDraftState()
        } catch is CancellationError {
        } catch {
            if loadRevision == revision { errorMessage = error.localizedDescription }
        }
    }

    func requestEdit(workspace: WorkspaceModel, action: @escaping @MainActor () -> Void) {
        guard canEdit else { return }
        guard hasChanges || !workspace.elasticsearchHasPendingChanges() else {
            errorMessage = AppCopy.current.text(
                "请先提交或放弃其他 Elasticsearch 更改。",
                "Commit or discard the other Elasticsearch changes first."
            )
            return
        }
        if workspace.safetyLock.isEnabled {
            pendingAction = action
            showsUnlockConfirmation = true
        } else {
            action()
        }
    }

    func confirmUnlock(workspace: WorkspaceModel) {
        workspace.safetyLock.disable()
        showsUnlockConfirmation = false
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    func cancelUnlock() {
        showsUnlockConfirmation = false
        pendingAction = nil
    }

    func beginAdding(workspace: WorkspaceModel) {
        requestEdit(workspace: workspace) { [weak self] in
            guard let self else { return }
            newBindingName = ""
            newBindingIsWriteIndex = false
            showsAddBinding = true
            errorMessage = nil
        }
    }

    func cancelAdding() {
        showsAddBinding = false
        newBindingName = ""
        newBindingIsWriteIndex = false
    }

    func addBinding(workspace: WorkspaceModel) {
        requestEdit(workspace: workspace) { [weak self] in self?.addBinding() }
    }

    private func addBinding() {
        guard let snapshot else { return }
        let entered = newBindingName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try WorkspaceElasticsearchIndexName.encodedPath(entered)
            let indexName: String
            let aliasName: String
            switch snapshot.selection.kind {
            case .elasticsearchIndex:
                indexName = snapshot.selection.objectName
                aliasName = entered
            case .elasticsearchAlias:
                indexName = entered
                aliasName = snapshot.selection.objectName
            default:
                throw WorkspaceElasticsearchAliasError.unsupportedResource
            }
            let binding = WorkspaceElasticsearchAliasBinding(
                indexName: indexName,
                aliasName: aliasName,
                isWriteIndex: snapshot.selection.kind == .elasticsearchAlias && newBindingIsWriteIndex ? true : nil,
                optionsJSON: Data("{}".utf8)
            )
            guard !rows.contains(where: { !$0.isRemoved && $0.binding.key == binding.key }) else {
                throw WorkspaceElasticsearchAliasError.duplicateBinding
            }
            if binding.isWriteIndex == true { clearOtherWriteIndices(except: nil) }
            rows.append(.init(id: UUID(), original: nil, binding: binding, isRemoved: false))
            showsAddBinding = false
            newBindingName = ""
            newBindingIsWriteIndex = false
            schedulePreparation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleRemoval(rowID: UUID, workspace: WorkspaceModel) {
        requestEdit(workspace: workspace) { [weak self] in
            guard let self, let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
            if rows[index].isNew {
                rows.remove(at: index)
            } else {
                rows[index].isRemoved.toggle()
            }
            schedulePreparation()
        }
    }

    func setWriteIndex(rowID: UUID, isWriteIndex: Bool, workspace: WorkspaceModel) {
        requestEdit(workspace: workspace) { [weak self] in
            guard let self, let index = rows.firstIndex(where: { $0.id == rowID }),
                  !rows[index].isRemoved else { return }
            if isWriteIndex { clearOtherWriteIndices(except: rowID) }
            rows[index].binding.isWriteIndex = isWriteIndex
            schedulePreparation()
        }
    }

    func discard() {
        guard !isCommitting, let snapshot else { return }
        prepareTask?.cancel()
        rows = workerRows(snapshot, preserving: rows)
        resetDraftState()
    }

    func stopReading() {
        loadRevision = UUID()
        isLoading = false
    }

    func requestCommit(workspace: WorkspaceModel) {
        guard canCommit else { return }
        requestEdit(workspace: workspace) { [weak self] in self?.commit(workspace: workspace) }
    }

    private func commit(workspace: WorkspaceModel) {
        guard canCommit, let prepared else { return }
        isCommitting = true
        commitTask = Task { [weak self] in
            guard let self else { return }
            var completed = false
            var attempted = false
            var requiresVerification = false
            do {
                let response = try await workspace.commitElasticsearchAliases(prepared)
                attempted = true
                completed = await worker.acknowledged(response)
                if !completed {
                    errorMessage = await worker.responseText(response)
                    requiresVerification = (200..<300).contains(response.statusCode)
                        || response.statusCode == 408 || response.statusCode >= 500
                }
            } catch let error as WorkspaceElasticsearchAliasNotSentError {
                errorMessage = error.localizedDescription
                isBlocked = true
            } catch {
                attempted = true
                requiresVerification = true
                errorMessage = error.localizedDescription
            }
            commitTask = nil
            if requiresVerification {
                recoveryTask = Task { [weak self] in
                    guard let self else { return }
                    var verified = false
                    do {
                        let request = try await worker.readRequest(prepared.baseline.selection)
                        let response = try await workspace.executeElasticsearchRequest(request)
                        verified = try await worker.matches(prepared, response: response)
                    } catch {}
                    await finishCommit(completed: verified, attempted: true,
                        uncertain: !verified, workspace: workspace)
                    recoveryTask = nil
                }
            } else {
                await finishCommit(completed: completed, attempted: attempted,
                    uncertain: false, workspace: workspace)
            }
        }
    }

    private func finishCommit(completed: Bool, attempted: Bool, uncertain: Bool,
                              workspace: WorkspaceModel) async {
        if completed {
            snapshot = snapshot.map {
                .init(selection: $0.selection, bindings: prepared?.desiredBindings ?? $0.bindings,
                    rawJSON: $0.rawJSON)
            }
            if let snapshot { rows = workerRows(snapshot, preserving: rows) }
            resetDraftState()
        } else if uncertain {
            isBlocked = true
            errorMessage = (errorMessage.map { $0 + "\n\n" } ?? "")
                + WorkspaceElasticsearchAliasError.uncertain.localizedDescription
        }
        isCommitting = false
        if attempted { await workspace.didMutateElasticsearchMapping() }
    }

    private func clearOtherWriteIndices(except rowID: UUID?) {
        for index in rows.indices where rows[index].id != rowID
            && !rows[index].isRemoved && rows[index].binding.isWriteIndex == true {
            rows[index].binding.isWriteIndex = false
        }
    }

    private func schedulePreparation() {
        prepareTask?.cancel()
        prepared = nil
        errorMessage = nil
        isBlocked = false
        let revision = UUID()
        editRevision = revision
        guard hasChanges, let snapshot else { return }
        let currentRows = rows
        prepareTask = Task { [weak self, worker] in
            guard let self else { return }
            defer { if editRevision == revision { prepareTask = nil } }
            do {
                let value = try await worker.prepare(snapshot: snapshot, rows: currentRows)
                try Task.checkCancellation()
                guard editRevision == revision else { return }
                prepared = value
            } catch is CancellationError {
            } catch {
                if editRevision == revision { errorMessage = error.localizedDescription }
            }
        }
    }

    private func workerRows(_ snapshot: WorkspaceElasticsearchAliasSnapshot,
                            preserving rows: [WorkspaceElasticsearchAliasEditorRow]) -> [WorkspaceElasticsearchAliasEditorRow] {
        let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.binding.key, $0.id) })
        return snapshot.bindings.map {
            .init(id: identities[$0.key] ?? UUID(), original: $0, binding: $0, isRemoved: false)
        }
    }

    private func resetDraftState() {
        prepareTask?.cancel()
        prepareTask = nil
        editRevision = UUID()
        prepared = nil
        errorMessage = nil
        isBlocked = false
        cancelAdding()
    }

    private func clearLoadedState() {
        snapshot = nil
        rows = []
        resetDraftState()
    }
}
