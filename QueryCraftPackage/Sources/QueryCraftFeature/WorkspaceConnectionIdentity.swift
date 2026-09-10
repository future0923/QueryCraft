import SwiftUI

struct WorkspaceConnectionIdentity: View {
    let profileName: String
    let endpoint: String
    let databaseName: String?
    let showsDatabase: Bool
    let connectionState: WorkspaceConnectionState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(profileName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            if !endpoint.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(endpoint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if showsDatabase {
                Divider()
                    .frame(height: 14)

                Image(systemName: "cylinder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(databaseDisplayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            WorkspaceToolbarConnectionStatusIcon(state: connectionState)
                .labelStyle(.iconOnly)
                .font(.callout)
        }
        .padding(.horizontal, 6)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var helpText: String {
        [profileName, endpoint, showsDatabase ? databaseDisplayName : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " - ")
    }

    private var databaseDisplayName: String {
        guard let databaseName, !databaseName.isEmpty else {
            return AppCopy.current.text("未选择数据库", "No Database")
        }
        return databaseName
    }

    private var accessibilityLabel: String {
        var components = [
            "\(AppCopy.current.text("连接", "Connection")): \(profileName)"
        ]
        if !endpoint.isEmpty {
            components.append(
                "\(AppCopy.current.text("地址", "Address")): \(endpoint)"
            )
        }
        if showsDatabase {
            components.append(
                "\(AppCopy.current.text("数据库", "Database")): \(databaseDisplayName)"
            )
        }
        components.append(connectionStateDescription)
        return components.joined(separator: ", ")
    }

    private var connectionStateDescription: String {
        switch connectionState {
        case .connecting:
            AppCopy.current.text("正在连接", "Connecting")
        case .connected:
            AppCopy.current.text("已连接", "Connected")
        case .failed:
            AppCopy.current.text("连接已断开", "Disconnected")
        }
    }
}
