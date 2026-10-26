import SwiftUI

private struct MCPCompactPermissionRowsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var mcpCompactPermissionRows: Bool {
        get { self[MCPCompactPermissionRowsKey.self] }
        set { self[MCPCompactPermissionRowsKey.self] = newValue }
    }
}

enum MCPPermissionLayout {
    static let controlWidth: CGFloat = 180
    static let scopeWidth: CGFloat = 180
    static let connectionMinimumWidth: CGFloat = 160
    static let connectionIdealWidth: CGFloat = 200
}

struct MCPPermissionGroupSection: View {
    @Bindable var model: MCPSettingsModel
    let group: MCPPermissionGroup
    @Environment(\.mcpCompactPermissionRows) private var compact
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var selection: MCPPermissionSelection { model.groupSelection(group) }

    var body: some View {
        Section {
            if !group.profiles.isEmpty {
            HStack {
                Text(copy("本组默认权限", "Default access for this group"))
                Spacer(minLength: 8)
                MCPPermissionPicker(selection: selection, choices: [.custom] + MCPPermissionSelection.accessChoices,
                    accessibilityLabel: copy("\(group.name)权限", "\(group.name) access")) {
                        model.setGroupSelection($0, for: group)
                    }
                    .frame(width: MCPPermissionLayout.controlWidth, height: 22, alignment: .trailing)
            }
            Text(copy("连接或对象已单独设置权限时，优先使用其设置；未设置时才继承本组权限。", "Explicit connection or object access takes precedence. This group default applies only when no more specific access is set."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
            }
            if !model.visibleProfiles(in: group).isEmpty || !model.visibleSSHProfiles(in: group).isEmpty {
                Group {
                    if !compact {
                        HStack(spacing: 12) {
                            Text(copy("连接", "Connection"))
                                .frame(minWidth: MCPPermissionLayout.connectionMinimumWidth,
                                       idealWidth: MCPPermissionLayout.connectionIdealWidth, maxWidth: .infinity, alignment: .leading)
                            Text(copy("访问权限", "Access"))
                                .frame(width: MCPPermissionLayout.controlWidth, alignment: .trailing)
                            Text(copy("访问范围", "Object scope"))
                                .frame(width: MCPPermissionLayout.scopeWidth, alignment: .trailing)
                        }
                    } else {
                        Text(copy("连接列表", "Connections")).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
            }
            ForEach(model.visibleProfiles(in: group)) { profile in
                MCPConnectionPermissionRow(model: model, profile: profile)
                    .id(profile.id.uuidString)
            }
            ForEach(model.visibleSSHProfiles(in: group)) { profile in
                MCPSSHConnectionPermissionRow(model: model, profile: profile)
                    .id("ssh-" + profile.id.uuidString)
            }
            if let id = group.groupID, !group.profiles.isEmpty {
                Toggle(copy("以后加入本组的连接也自动授权", "Automatically authorize future group members"), isOn: Binding(
                    get: { model.policy.allConnections || model.policy.groupIDs.contains(id) },
                    set: { model.setGroupAutomaticGrant($0, for: group) }))
                .toggleStyle(.checkbox).disabled(model.policy.allConnections)
                .font(MCPSettingsType.detail)
                .id("group-future-" + group.id)
            } else if !group.profiles.isEmpty {
                Text(copy("未分组的新增连接默认不授权；“全部连接”模式除外。", "New ungrouped connections remain unauthorized unless all connections are allowed."))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(group.name)
                Spacer()
                let allowed = group.profiles.filter { model.policy.includesConnection($0) }.count
                    + group.sshProfiles.filter { SSHAccess.current(id: $0.id, policy: model.policy) != .denied }.count
                let count = group.profiles.count + group.sshProfiles.count
                Text(copy("\(allowed) / \(count) 个连接已授权", "\(allowed) / \(count) authorized"))
                    .foregroundStyle(.secondary)
            }
        }
        .id(group.id)
    }
}
