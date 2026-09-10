import SwiftUI

struct RedisCommandArgumentSuggestionList: View {
    let suggestions: [RedisCommandArgumentSuggestion]
    let selectedIndex: Int
    let accept: (RedisCommandArgumentSuggestion) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions.indices, id: \.self) { index in
                    RedisCommandArgumentSuggestionRow(
                        suggestion: suggestions[index],
                        isSelected: index == selectedIndex,
                        accept: accept
                    )
                }
            }
            .padding(3)
        }
        .accessibilityLabel(
            AppCopy.current.text("Redis 参数候选", "Redis argument suggestions")
        )
    }
}
