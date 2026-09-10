import SwiftUI

struct RedisCommandCompletionList: View {
    let entries: [RedisCommandCatalogEntry]
    let selectedIndex: Int
    let accept: (RedisCommandCatalogEntry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    RedisCommandCompletionRow(
                        entry: entries[index],
                        isSelected: index == selectedIndex,
                        accept: accept
                    )
                }
            }
            .padding(3)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .accessibilityLabel(
            AppCopy.current.text("Redis 命令补全", "Redis command completions")
        )
    }
}
