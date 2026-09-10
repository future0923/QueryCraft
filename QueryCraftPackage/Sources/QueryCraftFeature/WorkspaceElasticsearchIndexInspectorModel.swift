import Foundation
import Observation

@MainActor @Observable
final class WorkspaceElasticsearchIndexInspectorModel {
    private(set) var snapshot: WorkspaceIndexSettingsSnapshot?
    private(set) var rawSettingsText = ""
    private var defaultConsoleSource = ""
    private var preparedConsoleSource: String?
    private(set) var replicas = ""
    private(set) var interval = ""
    private(set) var isEditing = false
    private(set) var isLoading = false
    private(set) var isCommitting = false
    private(set) var isBlocked = false
    private(set) var prepared: WorkspacePreparedIndexSettings?
    private(set) var errorMessage: String?
    var showsUnlockConfirmation = false
    @ObservationIgnored private var pendingAction: (@MainActor () -> Void)?
    @ObservationIgnored private let worker = WorkspaceIndexSettingsWorker()
    @ObservationIgnored private var loadRevision = UUID()
    @ObservationIgnored private var editRevision = UUID()
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    var hasChanges: Bool {
        guard let index = snapshot?.editableIndex else { return false }
        return replicas != (index.effective(WorkspaceIndexSettingsWorker.replicasKey) ?? "")
            || interval != (index.effective(WorkspaceIndexSettingsWorker.intervalKey) ?? "")
    }
    var canEdit: Bool { snapshot?.editableIndex != nil && !isLoading && !isCommitting && !isBlocked }
    var canCommit: Bool { hasChanges && prepared != nil && !isCommitting && !isBlocked }
    var canOpenSettingsRequest: Bool {
        snapshot != nil && !isLoading && !isCommitting && (!hasChanges || prepared != nil)
    }

    func openSettingsRequest(workspace: WorkspaceModel) {
        guard canOpenSettingsRequest else { return }
        workspace.openElasticsearchRequestSource(preparedConsoleSource ?? defaultConsoleSource)
    }

    func load(selection: WorkspaceDatabaseObjectSelection, workspace: WorkspaceModel) async {
        await load { [worker] in
            try await worker.load(selection) { request in try await workspace.executeElasticsearchRequest(request) }
        }
    }

    func load(fetch: () async throws -> WorkspaceIndexSettingsSnapshot) async {
        guard !hasChanges, !isCommitting else { return }
        let revision = UUID(); loadRevision = revision; isLoading = true
        defer { if loadRevision == revision { isLoading = false } }
        do {
            let loaded = try await fetch()
            let rawText = try await worker.rawSettingsText(loaded)
            let source = try await worker.consoleSource(loaded)
            try Task.checkCancellation()
            guard loadRevision == revision, !hasChanges, !isCommitting else { return }
            snapshot = loaded
            rawSettingsText = rawText; defaultConsoleSource = source
            resetDraft()
        } catch is CancellationError {} catch {
            if loadRevision == revision { errorMessage = error.localizedDescription }
        }
    }

    func requestEdit(workspace: WorkspaceModel, action: (@MainActor () -> Void)? = nil) {
        guard canEdit else { return }
        guard hasChanges || !workspace.elasticsearchHasPendingChanges() else {
            errorMessage = AppCopy.current.text("请先提交或放弃文档或 Mapping 更改。", "Commit or discard document or Mapping changes first.")
            return
        }
        let action = action ?? { [weak self] in self?.isEditing = true }
        if workspace.safetyLock.isEnabled { pendingAction = action; showsUnlockConfirmation = true }
        else { action() }
    }
    func confirmUnlock(workspace: WorkspaceModel) {
        workspace.safetyLock.disable(); showsUnlockConfirmation = false
        let action = pendingAction; pendingAction = nil; action?()
    }
    func cancelUnlock() { showsUnlockConfirmation = false; pendingAction = nil }

    func update(replicas: String, interval: String, workspace: WorkspaceModel) {
        guard isEditing, canEdit else { return }
        requestEdit(workspace: workspace) { [weak self] in self?.update(replicas: replicas, interval: interval) }
    }

    private func update(replicas: String, interval: String) {
        self.replicas = replicas; self.interval = interval
        prepareTask?.cancel(); prepared = nil; preparedConsoleSource = nil; errorMessage = nil
        let revision = UUID(); editRevision = revision
        guard hasChanges, let snapshot else { return }
        prepareTask = Task { [weak self, worker] in
            guard let self else { return }
            defer { if editRevision == revision { prepareTask = nil } }
            do {
                let value = try await worker.prepare(snapshot, replicas: replicas, interval: interval)
                let source = value.changes.isEmpty ? nil : try await worker.consoleSource(snapshot, prepared: value)
                try Task.checkCancellation()
                guard editRevision == revision else { return }
                prepared = value.changes.isEmpty ? nil : value
                preparedConsoleSource = source
            } catch is CancellationError {} catch {
                if editRevision == revision { errorMessage = error.localizedDescription }
            }
        }
    }

    func discard() {
        guard !isCommitting else { return }
        resetDraft()
    }
    private func resetDraft() {
        prepareTask?.cancel(); prepareTask = nil; editRevision = UUID()
        replicas = snapshot?.editableIndex?.effective(WorkspaceIndexSettingsWorker.replicasKey) ?? ""
        interval = snapshot?.editableIndex?.effective(WorkspaceIndexSettingsWorker.intervalKey) ?? ""
        prepared = nil; preparedConsoleSource = nil; errorMessage = nil; isEditing = false; isBlocked = false
    }
    func stopReading() { loadRevision = UUID(); isLoading = false }

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
            var requiresVerification = false
            var attempted = false
            do {
                let response = try await workspace.commitElasticsearchIndexSettings(prepared)
                attempted = true
                // Never throw cancellation away over a complete server acknowledgement.
                completed = await worker.acknowledged(response)
                if !completed {
                    errorMessage = await worker.responseText(response)
                    requiresVerification = (200..<300).contains(response.statusCode) || response.statusCode == 408 || response.statusCode >= 500
                }
            } catch let error as WorkspaceIndexSettingsNotSentError {
                errorMessage = error.localizedDescription; isBlocked = true
            } catch {
                attempted = true; requiresVerification = true; errorMessage = error.localizedDescription
            }
            commitTask = nil
            if requiresVerification {
                // A separate owned task permits authoritative reads even when transport
                // ended by cancellation. No path automatically resends the PUT.
                recoveryTask = Task { [weak self] in
                    guard let self else { return }
                    var verified = false
                    do {
                        let request = try await worker.settingsRequest(prepared.baseline.selection)
                        verified = try await worker.matches(prepared, response: workspace.executeElasticsearchRequest(request))
                    } catch { /* Keep the complete write error and retained draft. */ }
                    await finishCommit(completed: verified, attempted: true, uncertain: !verified, workspace: workspace)
                    recoveryTask = nil
                }
            } else { await finishCommit(completed: completed, attempted: attempted, uncertain: false, workspace: workspace) }
        }
    }

    private func finishCommit(completed: Bool, attempted: Bool, uncertain: Bool, workspace: WorkspaceModel) async {
        if completed { resetDraft() }
        else if uncertain {
            isBlocked = true
            errorMessage = (errorMessage.map { $0 + "\n\n" } ?? "") + WorkspaceIndexSettingsError.uncertain.localizedDescription
        }
        isCommitting = false
        if attempted { await workspace.didMutateElasticsearchMapping() }
    }
}
