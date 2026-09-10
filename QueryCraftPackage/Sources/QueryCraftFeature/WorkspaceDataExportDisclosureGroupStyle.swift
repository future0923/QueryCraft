import SwiftUI

struct WorkspaceDataExportDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: configuration.isExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)

                    configuration.label
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
