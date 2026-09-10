import SwiftUI

struct WorkspaceRedisSidebarFooter: View {
    @Bindable var model: WorkspaceModel
    let loadAll: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(statusText)

            Spacer(minLength: 2)

            if model.isLoadingRedisKeys {
                WorkspaceInlineIconButton(
                    systemImageName: "stop.fill",
                    title: AppCopy.current.text("停止加载", "Stop Loading"),
                    isEnabled: true,
                    action: model.stopRedisKeyLoading
                )
            }

            RedisKeyLoadMenu(
                isEnabled: !model.isLoadingRedisKeys
                    && !model.isRedisKeyScanComplete,
                loadMore: {
                    model.startRedisKeyPageLoad(reset: false)
                },
                loadAll: loadAll
            )

            WorkspaceInlineIconButton(
                systemImageName: "arrow.clockwise",
                title: AppCopy.current.text("刷新 Key", "Refresh Keys"),
                isEnabled: !model.isLoadingRedisKeys
                    && model.connectionState == .connected
            ) {
                model.startRedisKeyPageLoad(reset: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        let count = model.isLoadingRedisKeys
            ? model.redisKeyLoadDiscoveredCount
            : model.redisKeys.count
        if !model.activeRedisKeySearchText.isEmpty {
            return model.isLoadingRedisKeys
                ? AppCopy.current.text(
                    "正在扫描 · 找到 \(count) 个",
                    "Scanning · \(count) found"
                )
                : AppCopy.current.text(
                    "找到 \(count) 个",
                    "\(count) found"
                )
        }
        if let total = model.currentRedisDatabaseReportedKeyCount {
            return model.isLoadingAllRedisKeys
                ? AppCopy.current.text(
                    "正在加载 \(count) / \(total)",
                    "Loading \(count) / \(total)"
                )
                : AppCopy.current.text(
                    "已加载 \(count) / \(total)",
                    "\(count) / \(total) loaded"
                )
        }
        return model.isLoadingRedisKeys
            ? AppCopy.current.text(
                "正在加载 · \(count) 个",
                "Loading · \(count)"
            )
            : AppCopy.current.text(
                "已加载 \(count) 个",
                "\(count) loaded"
            )
    }
}
