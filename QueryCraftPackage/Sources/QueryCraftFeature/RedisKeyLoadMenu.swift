import SwiftUI

struct RedisKeyLoadMenu: View {
    let isEnabled: Bool
    let loadMore: () -> Void
    let loadAll: () -> Void

    var body: some View {
        Menu(
            AppCopy.current.text("加载", "Load"),
            systemImage: "arrow.down.circle"
        ) {
            Button(
                AppCopy.current.text("加载更多", "Load More"),
                systemImage: "arrow.down"
            ) {
                loadMore()
            }
            Button(
                AppCopy.current.text("加载全部", "Load All"),
                systemImage: "arrow.down.to.line"
            ) {
                loadAll()
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEnabled)
    }
}
