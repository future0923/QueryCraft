import Observation

@MainActor
@Observable
final class WorkspaceToolbarModel {
    let presentation: WorkspaceWindowPresentation
    var showsSQLPreview = false
    var showsDisableSafetyLockConfirmation = false

    private let createQueryDocumentAction: @MainActor () -> Void
    private let refreshWorkspaceAction: @MainActor () -> Void

    init(
        presentation: WorkspaceWindowPresentation,
        createQueryDocument: @escaping @MainActor () -> Void,
        refreshWorkspace: @escaping @MainActor () -> Void
    ) {
        self.presentation = presentation
        createQueryDocumentAction = createQueryDocument
        refreshWorkspaceAction = refreshWorkspace
    }

    var model: WorkspaceModel {
        presentation.context.model
    }

    var selectedContentID: WorkspaceContentTabID? {
        presentation.context.tabsModel.selectedContentID
    }

    var canCreateQuery: Bool {
        model.connectionState == .connected
    }

    var showsDatabaseSelection: Bool {
        model.databaseType != .elasticsearch
    }

    var showsInspector: Bool {
        presentation.showsInspector
    }

    var selectedContentUsesContextualRefresh: Bool {
        guard let item = presentation.context.tabsModel.selectedContentItem
        else { return false }
        switch item {
        case .databaseObject, .redisKey:
            return true
        case .query, .newTable, .redisCommand, .elasticsearchRequest:
            return false
        }
    }

    var selectedContentRefreshActions: WorkspaceContentRefreshActions? {
        guard selectedContentUsesContextualRefresh else { return nil }
        return presentation.context.contentRefreshRegistry.actions(
            for: selectedContentID
        )
    }

    var refreshActionTitle: String {
        if refreshActionDidComplete {
            return AppCopy.current.text("刷新完成", "Refresh Complete")
        }
        return selectedContentRefreshActions?.title
            ?? AppCopy.current.text("刷新", "Refresh")
    }

    var refreshActionSystemImage: String {
        if refreshActionIsStopping {
            return "stop.fill"
        }
        return refreshActionDidComplete ? "checkmark" : "arrow.clockwise"
    }

    var refreshActionIsStopping: Bool {
        selectedContentRefreshActions?.isStopping == true
    }

    var refreshActionDidComplete: Bool {
        selectedContentRefreshActions?.didComplete == true
    }

    var isRefreshActionDisabled: Bool {
        model.connectionState != .connected
            || (selectedContentUsesContextualRefresh
                && selectedContentRefreshActions == nil)
    }

    var selectedPendingChangesActions: WorkspacePendingChangesActions? {
        presentation.context.pendingChangesRegistry.actions(
            for: selectedContentID
        )
    }

    var pendingChangeStatements: [WorkspaceSQLPreviewStatement] {
        selectedPendingChangesActions?.statements ?? []
    }

    var pendingChangesPreview: WorkspacePendingChangesPreview {
        selectedPendingChangesActions?.previewContent ?? .sql([])
    }

    var pendingChangesPreviewIsRedis: Bool {
        pendingChangesPreview.isRedis
    }

    var pendingChangesPreviewIsElasticsearch: Bool {
        pendingChangesPreview.isElasticsearch
    }

    var hasPendingChanges: Bool {
        selectedPendingChangesActions?.hasChanges == true
    }

    var pendingChangesAreCommitting: Bool {
        selectedPendingChangesActions?.isCommitting == true
    }

    var canPreviewPendingChanges: Bool {
        selectedPendingChangesActions?.canPreview == true
    }

    var canDiscardPendingChanges: Bool {
        hasPendingChanges && !pendingChangesAreCommitting
    }

    var canCommitPendingChanges: Bool {
        model.connectionState == .connected
            && canPreviewPendingChanges
            && selectedPendingChangesActions?.canCommit == true
            && !pendingChangesAreCommitting
    }

    var focusedPendingChangesActions: WorkspacePendingChangesActions? {
        guard let actions = selectedPendingChangesActions else { return nil }
        return WorkspacePendingChangesActions(
            hasChanges: actions.hasChanges,
            previewContent: actions.previewContent,
            canCommit: actions.canCommit,
            isCommitting: actions.isCommitting,
            discard: discardPendingChanges,
            preview: previewPendingChanges,
            commit: commitPendingChanges
        )
    }

    var discardPendingChangesHelp: String {
        AppCopy.current.text(
            "放弃全部更改 (⌘⇧⌫)",
            "Discard All Changes (⌘⇧⌫)"
        )
    }

    var previewPendingChangesHelp: String {
        if pendingChangesPreviewIsElasticsearch {
            return AppCopy.current.text(
                "预览请求 (⌘⇧P)",
                "Preview Request (⌘⇧P)"
            )
        }
        return pendingChangesPreviewIsRedis
            ? AppCopy.current.text(
                "预览命令 (⌘⇧P)",
                "Preview Commands (⌘⇧P)"
            )
            : AppCopy.current.text(
                "预览 SQL (⌘⇧P)",
                "Preview SQL (⌘⇧P)"
            )
    }

    var previewPendingChangesTitle: String {
        if pendingChangesPreviewIsElasticsearch {
            return AppCopy.current.text("预览请求", "Preview Request")
        }
        if pendingChangesPreviewIsRedis {
            return AppCopy.current.text("预览命令", "Preview Commands")
        }
        return AppCopy.current.text("预览 SQL", "Preview SQL")
    }

    var commitPendingChangesHelp: String {
        AppCopy.current.text(
            "提交更改 (⌘S)",
            "Commit Changes (⌘S)"
        )
    }

    func createQueryDocument() {
        guard canCreateQuery else { return }
        createQueryDocumentAction()
    }

    func performRefreshAction() {
        guard !isRefreshActionDisabled else { return }
        if selectedContentUsesContextualRefresh {
            selectedContentRefreshActions?.perform()
        } else {
            refreshWorkspaceAction()
        }
    }

    func refreshWorkspace() {
        refreshWorkspaceAction()
    }

    func enableSafetyLock() {
        model.safetyLock.enable()
    }

    func disableSafetyLock() {
        model.safetyLock.disable()
    }

    func toggleSafetyLock() {
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockConfirmation = true
        } else {
            enableSafetyLock()
        }
    }

    func discardPendingChanges() {
        guard canDiscardPendingChanges else { return }
        showsSQLPreview = false
        selectedPendingChangesActions?.discard()
    }

    func previewPendingChanges() {
        guard canPreviewPendingChanges else { return }
        showsSQLPreview = true
    }

    func commitPendingChanges() {
        guard canCommitPendingChanges else { return }
        selectedPendingChangesActions?.commit()
    }

    func toggleInspector() {
        presentation.setInspectorVisible(!presentation.showsInspector)
    }

    func closeSQLPreview() {
        showsSQLPreview = false
    }
}
