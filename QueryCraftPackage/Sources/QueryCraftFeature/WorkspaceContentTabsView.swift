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

    private var visibleContentItems: [WorkspaceContentTabItem] {
        guard model.databaseType == .kafka else {
            return tabsModel.contentItems
        }

        return tabsModel.contentItems.filter {
            guard case let .databaseObject(selection) = $0 else {
                return false
            }
            return selection.kind == .table
                && selection.databaseName == model.databaseContextName
        }
    }

    private func contentRevision(for contentItems: [WorkspaceContentTabItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(tabsModel.contentRevision)
        hasher.combine(model.databaseType.rawValue)
        hasher.combine(model.databaseContextName)
        for item in contentItems {
            hasher.combine(item.id)
        }
        return hasher.finalize()
    }

    var body: some View {
        // Editor tabs belong to their original connection type. Keep this
        // guard at the view boundary as a defensive fallback for a restored
        // workspace whose tabs were created before it was connected to Kafka.
        let contentItems = visibleContentItems
        let contentRevision = contentRevision(for: contentItems)
        let selectedContentID = contentItems.contains {
            $0.id == tabsModel.selectedContentID
        } ? tabsModel.selectedContentID : nil

        VStack(spacing: 0) {
            if !contentItems.isEmpty {
                WorkspaceContentTabStrip(
                    tabsModel: tabsModel,
                    items: contentItems,
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
                                : model.databaseType == .kafka
                                    ? "point.3.connected.trianglepath.dotted"
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
                                : model.databaseType == .kafka
                                    ? AppCopy.current.text(
                                        "请选择 Topic 查看消息。",
                                        "Select a topic to browse its messages."
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
        .task(id: model.databaseType) {
            guard model.databaseType == .kafka else { return }
            tabsModel.removeQueryDocuments()
            guard let selectedContentID = tabsModel.selectedContentID else {
                return
            }
            if contentItems.contains(where: { $0.id == selectedContentID }) {
                selectContent(selectedContentID)
            } else {
                // Do not activate a restored object that was filtered out for
                // the current Kafka database context.
                model.sidebarSelection = nil
            }
        }
    }
}
