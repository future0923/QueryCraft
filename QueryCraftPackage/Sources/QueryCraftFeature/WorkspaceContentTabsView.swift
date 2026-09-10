import SwiftUI

struct WorkspaceContentTabsView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var tabsModel: WorkspaceContentTabsModel
    let contentRefreshRegistry: WorkspaceContentRefreshRegistry
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let inspectorRegistry: WorkspaceInspectorRegistry
    let objectDetailTabRegistry: WorkspaceDatabaseObjectDetailTabRegistry
    let redisKeyActionRegistry: WorkspaceRedisKeyActionRegistry
    let hostController: WorkspaceRetainedContentHostController
    let retainedHostControllers: [WorkspaceRetainedContentHostController]
    let selectContent: @MainActor (WorkspaceContentTabID) -> Void
    let performContentTabAction: @MainActor (
        WorkspaceContentTabAction
    ) -> Void

    var body: some View {
        let contentItems = tabsModel.contentItems
        let contentRevision = tabsModel.contentRevision
        let selectedContentID = tabsModel.selectedContentID

        VStack(spacing: 0) {
            if !contentItems.isEmpty {
                WorkspaceContentTabStrip(
                    tabsModel: tabsModel,
                    selectContent: selectContent,
                    performAction: performContentTabAction
                )
                .frame(height: WorkspaceContentTabStripLayout.bandHeight)
            }

            ZStack {
                WorkspaceContentTabHost(
                    model: model,
                    items: contentItems,
                    contentRevision: contentRevision,
                    selectedContentID: selectedContentID,
                    contentRefreshRegistry: contentRefreshRegistry,
                    pendingChangesRegistry: pendingChangesRegistry,
                    inspectorRegistry: inspectorRegistry,
                    objectDetailTabRegistry: objectDetailTabRegistry,
                    redisKeyActionRegistry: redisKeyActionRegistry,
                    hostController: hostController,
                    retainedHostControllers: retainedHostControllers
                )

                if contentItems.isEmpty {
                    ContentUnavailableView(
                        AppCopy.current.text("未选择内容", "No Selection"),
                        systemImage: model.databaseType == .redis
                            ? "key"
                            : model.databaseType == .elasticsearch
                                ? "doc.text.magnifyingglass"
                                : "tablecells",
                        description: Text(
                            model.databaseType == .redis
                                ? AppCopy.current.text(
                                    "请选择 Key 或创建 Command。",
                                    "Select a key or create a Command."
                                )
                                : model.databaseType == .elasticsearch
                                    ? AppCopy.current.text(
                                        "请选择索引、Alias、数据流或创建请求。",
                                        "Select an index, alias, data stream, or create a request."
                                    )
                                : AppCopy.current.text(
                                    "请选择数据库对象或创建查询。",
                                    "Select a database object or create a query."
                                )
                        )
                    )
                }
            }
        }
    }
}
