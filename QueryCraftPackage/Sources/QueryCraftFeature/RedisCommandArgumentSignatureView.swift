import SwiftUI

struct RedisCommandArgumentSignatureView: View {
    let entry: RedisCommandCatalogEntry
    let argument: RedisCommandArgument?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.syntax)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            if let argument {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(argument.displayName)
                        .font(.system(.caption, design: .monospaced))
                        .bold()
                        .foregroundStyle(.tint)
                    Text(argument.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
