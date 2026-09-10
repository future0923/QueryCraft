import SwiftUI

struct RedisCommandCompletionRow: View {
    let entry: RedisCommandCatalogEntry
    let isSelected: Bool
    let accept: (RedisCommandCatalogEntry) -> Void

    var body: some View {
        Button {
            accept(entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.syntax)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(summaryColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(titleColor)
        .background(backgroundColor)
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityIdentifier("redisCommandCompletion.\(entry.id)")
    }

    private var titleColor: Color {
        Color(nsColor: .labelColor)
    }

    private var summaryColor: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    private var backgroundColor: Color {
        isSelected
            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            : .clear
    }
}
