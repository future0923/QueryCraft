import SwiftUI

struct WorkspaceContentTabHost: NSViewControllerRepresentable {
    let model: WorkspaceModel
    let items: [WorkspaceContentTabItem]
    let contentRevision: Int
    let selectedContentID: WorkspaceContentTabID?
    let contentRefreshRegistry: WorkspaceContentRefreshRegistry
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let inspectorRegistry: WorkspaceInspectorRegistry
    let objectDetailTabRegistry: WorkspaceDatabaseObjectDetailTabRegistry
    let redisKeyActionRegistry: WorkspaceRedisKeyActionRegistry
    let hostController: WorkspaceRetainedContentHostController
    let retainedHostControllers: [WorkspaceRetainedContentHostController]

    func makeNSViewController(
        context: Context
    ) -> WorkspaceContentTabHostContainerController {
        WorkspaceContentTabHostContainerController()
    }

    func updateNSViewController(
        _ controller: WorkspaceContentTabHostContainerController,
        context: Context
    ) {
        controller.show(
            hostController,
            retaining: retainedHostControllers
        )
        hostController.update(
            model: model,
            items: items,
            contentRevision: contentRevision,
            selectedContentID: selectedContentID,
            contentRefreshRegistry: contentRefreshRegistry,
            pendingChangesRegistry: pendingChangesRegistry,
            inspectorRegistry: inspectorRegistry,
            objectDetailTabRegistry: objectDetailTabRegistry,
            redisKeyActionRegistry: redisKeyActionRegistry
        )
    }
}
