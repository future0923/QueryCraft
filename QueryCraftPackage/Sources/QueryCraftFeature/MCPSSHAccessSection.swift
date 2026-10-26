import SwiftUI

/// SSH uses the same catalog, columns and settings draft as other connection types.
struct MCPSSHConnectionPermissionRow: View {
    @Bindable var model: MCPSettingsModel
    let profile: SSHConnection
    @Environment(\.mcpCompactPermissionRows) private var compact
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var access: SSHAccountAccess { SSHAccountAccess(id: profile.id, policy: model.policy) }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    connectionInfo
                    HStack(alignment: .top, spacing: 12) {
                        permissionControl
                        Spacer(minLength: 0)
                        scopeControl
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    connectionInfo.frame(minWidth: MCPPermissionLayout.connectionMinimumWidth,
                        idealWidth: MCPPermissionLayout.connectionIdealWidth, maxWidth: .infinity, alignment: .leading)
                    permissionControl
                    scopeControl
                }
            }
        }.padding(.vertical, 8)
    }

    private var connectionInfo: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(profile.name).fontWeight(.medium).lineLimit(1).help(profile.name)
            Text("SSH · \(profile.host):\(profile.port)")
                .font(MCPSettingsType.detail).foregroundStyle(.secondary).lineLimit(1)
                .help("\(profile.username)@\(profile.host):\(profile.port)\n\(profile.id)")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionControl: some View {
        Picker(copy("访问权限", "Access"), selection: Binding(
            get: { access.access },
            set: { value in model.updateSSHAccess(for: profile.id) { $0.access = value } }
        )) {
            ForEach(SSHAccess.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu)
        .accessibilityLabel(copy("\(profile.name)权限", "\(profile.name) access"))
        .frame(width: MCPPermissionLayout.controlWidth, height: 22, alignment: .trailing)
    }

    private var scopeControl: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Menu(copy("设置范围…", "Configure scope…")) {
                Toggle(copy("读取文件", "Read files"), isOn: grant(\.fileRead))
                Toggle(copy("上传与下载", "Upload and download"), isOn: grant(\.fileTransfer))
                Toggle(copy("创建、移动与删除", "Create, move and delete"), isOn: grant(\.fileManagement))
            }
            .menuStyle(.borderlessButton).fixedSize().frame(height: 22)
            .disabled(access.access == .denied)
            .accessibilityLabel(copy("\(profile.name)文件范围", "\(profile.name) file scope"))
            Text(MCPPermissionSummary.sshScope(access))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary).lineLimit(1)
                .help(MCPPermissionSummary.sshScope(access))
        }.frame(width: MCPPermissionLayout.scopeWidth, alignment: .trailing)
    }

    private func grant(_ keyPath: WritableKeyPath<SSHAccountAccess, Bool>) -> Binding<Bool> {
        Binding(get: { access[keyPath: keyPath] }, set: { value in
            model.updateSSHAccess(for: profile.id) { $0[keyPath: keyPath] = value }
        })
    }
}
