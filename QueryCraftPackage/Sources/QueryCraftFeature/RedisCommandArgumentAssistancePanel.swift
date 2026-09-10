import SwiftUI

struct RedisCommandArgumentAssistancePanel: View {
    let entry: RedisCommandCatalogEntry
    let argument: RedisCommandArgument?
    let suggestions: [RedisCommandArgumentSuggestion]
    let selectedIndex: Int
    let accept: (RedisCommandArgumentSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            RedisCommandArgumentSignatureView(
                entry: entry,
                argument: argument
            )

            if !suggestions.isEmpty {
                Divider()
                RedisCommandArgumentSuggestionList(
                    suggestions: suggestions,
                    selectedIndex: selectedIndex,
                    accept: accept
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .accessibilityLabel(
            AppCopy.current.text("Redis 命令参数提示", "Redis command argument help")
        )
    }
}
