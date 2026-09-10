import Foundation
import SwiftUI

struct WorkspaceRedisKeyInspectorView: View {
    let context: WorkspaceRedisKeyInspectorContext
    let searchText: String

    var body: some View {
        switch context.state {
        case .loading:
            VStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                WorkspaceDatabaseDataProgressBar(
                    isActive: true,
                    accessibilityLabel: AppCopy.current.text(
                        "正在加载 Key 信息",
                        "Loading key information"
                    )
                )
            }

        case let .failed(message):
            ContentUnavailableView {
                Label(
                    AppCopy.current.text(
                        "无法加载 Key 信息",
                        "Unable to Load Key Information"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                Button(
                    AppCopy.current.text("重试", "Retry"),
                    systemImage: "arrow.clockwise",
                    action: context.retry
                )
            }

        case let .loaded(details):
            RedisKeyInspectorMetadataList(
                details: details,
                searchText: searchText
            )
        }
    }
}
