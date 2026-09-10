import SwiftUI

struct ConnectionProfilesHeader: View {
    let profileCount: Int
    let createProfile: () -> Void
    let createGroup: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(AppCopy.current.connections)
                .font(.headline)

            Text(profileCount, format: .number)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button(
                AppCopy.current.text("新建连接", "New Connection"),
                systemImage: "plus",
                action: createProfile
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help(AppCopy.current.text("新建连接", "New Connection"))
            .accessibilityIdentifier("addConnectionButton")

            Button(
                AppCopy.current.text("新建连接分组", "New Connection Group"),
                systemImage: "folder.badge.plus",
                action: createGroup
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help(AppCopy.current.text("新建连接分组", "New Connection Group"))
            .accessibilityIdentifier("addConnectionGroupButton")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
