import SwiftUI

struct RedisCollectionValueLoadControls: View {
    static let width: CGFloat = 52
    static let loadMoreSystemImageName = "chevron.right"
    static let loadAllSystemImageName = "chevron.forward.2"

    let isEnabled: Bool
    let loadMore: @MainActor @Sendable () -> Void
    let loadAll: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 4) {
            WorkspaceInlineIconButton(
                systemImageName: Self.loadMoreSystemImageName,
                title: Self.loadMoreTitle,
                isEnabled: isEnabled,
                action: loadMore
            )
            WorkspaceInlineIconButton(
                systemImageName: Self.loadAllSystemImageName,
                title: Self.loadAllTitle,
                isEnabled: isEnabled,
                action: loadAll
            )
        }
        .frame(width: Self.width)
        .accessibilityIdentifier("redisCollectionValueLoadControls")
    }

    static var loadMoreTitle: String {
        AppCopy.current.text(
            "加载下一页（500）",
            "Load Next Page (500)"
        )
    }

    static var loadAllTitle: String {
        AppCopy.current.text(
            "加载全部值",
            "Load All Values"
        )
    }
}
