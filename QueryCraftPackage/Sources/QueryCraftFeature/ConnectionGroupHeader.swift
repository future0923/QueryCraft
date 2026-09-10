import SwiftUI

struct ConnectionGroupHeader: View {
    let title: String
    let profileCount: Int
    let systemImage: String?
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(profileCount, format: .number)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppCopy.current.text(
                "\(title)，\(profileCount) 个连接",
                "\(title), \(profileCount) connections"
            )
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
