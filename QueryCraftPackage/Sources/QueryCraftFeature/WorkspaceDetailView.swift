import SwiftUI

struct WorkspaceDetailView: View {
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
    let retryConnection: @MainActor () -> Void

    var body: some View {
        if model.connectionState == .connected
            || !tabsModel.contentItems.isEmpty
        {
            WorkspaceContentTabsView(
                model: model,
                tabsModel: tabsModel,
                contentRefreshRegistry: contentRefreshRegistry,
                pendingChangesRegistry: pendingChangesRegistry,
                inspectorRegistry: inspectorRegistry,
                objectDetailTabRegistry: objectDetailTabRegistry,
                redisKeyActionRegistry: redisKeyActionRegistry,
                hostController: hostController,
                retainedHostControllers: retainedHostControllers,
                selectContent: selectContent,
                performContentTabAction: performContentTabAction
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if case let .failed(message) = model.connectionState {
                    WorkspaceConnectionFailureBar(
                        message: message,
                        retry: retryConnection
                    )
                }
            }
        } else {
            switch model.connectionState {
            case .connecting:
                ContentUnavailableView {
                    Label(
                        AppCopy.current.text("正在连接", "Connecting"),
                        systemImage: "network"
                    )
                } description: {
                    Text(
                        AppCopy.current.text(
                            "正在打开数据库会话。",
                            "Opening the database session."
                        )
                    )
                }

            case .connected:
                EmptyView()

            case let .failed(message):
                ContentUnavailableView {
                    Label(
                        AppCopy.current.text("连接失败", "Connection Failed"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button(
                        AppCopy.current.text("重试", "Retry"),
                        systemImage: "arrow.clockwise",
                        action: retryConnection
                    )
                }
            }
        }
    }
}
