import Foundation

@MainActor
final class WorkspaceDatabaseContext: Identifiable {
    let id: UUID
    let model: WorkspaceModel
    let tabsModel: WorkspaceContentTabsModel
    let contentHostController = WorkspaceRetainedContentHostController()
    let contentRefreshRegistry = WorkspaceContentRefreshRegistry()
    let pendingChangesRegistry = WorkspacePendingChangesRegistry()
    let inspectorRegistry = WorkspaceInspectorRegistry()
    let objectDetailTabRegistry = WorkspaceDatabaseObjectDetailTabRegistry()
    let redisKeyActionRegistry = WorkspaceRedisKeyActionRegistry()

    init(
        id: UUID = UUID(),
        model: WorkspaceModel,
        tabsModel: WorkspaceContentTabsModel = WorkspaceContentTabsModel()
    ) {
        self.id = id
        self.model = model
        self.tabsModel = tabsModel
        model.elasticsearchHasPendingChanges = { [weak pendingChangesRegistry] in
            pendingChangesRegistry?.hasChanges ?? false
        }
    }
}
