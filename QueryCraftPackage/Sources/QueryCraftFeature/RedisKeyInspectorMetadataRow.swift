import SwiftUI

struct RedisKeyInspectorMetadataRow: View {
    let item: WorkspaceRedisKeyInspectorItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.label)
                .font(.subheadline)
                .lineLimit(1)
                .help(item.label)

            Text(item.value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                }
                .help(item.value)
        }
        .accessibilityElement(children: .combine)
    }
}
