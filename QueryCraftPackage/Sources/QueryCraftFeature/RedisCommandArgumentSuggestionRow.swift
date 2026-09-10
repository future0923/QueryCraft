import SwiftUI

struct RedisCommandArgumentSuggestionRow: View {
    let suggestion: RedisCommandArgumentSuggestion
    let isSelected: Bool
    let accept: (RedisCommandArgumentSuggestion) -> Void

    var body: some View {
        Button(action: acceptSuggestion) {
            HStack(spacing: 10) {
                Text(suggestion.value)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                : .clear
        )
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityIdentifier("redisArgumentSuggestion.\(suggestion.id)")
    }

    private func acceptSuggestion() {
        accept(suggestion)
    }
}
