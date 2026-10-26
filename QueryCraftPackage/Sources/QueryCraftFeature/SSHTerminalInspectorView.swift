import SwiftUI

enum SSHTerminalInspectorTab: String, CaseIterable, Identifiable {
    case scripts, connection
    var id: Self { self }
    var title: String {
        switch self {
        case .scripts: AppCopy.current.text("Shell 脚本", "Shell Scripts")
        case .connection: AppCopy.current.text("连接信息", "Connection Info")
        }
    }
}

struct SSHTerminalInspectorView: View {
    @Bindable var model: SSHTerminalWorkspace
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            Picker(AppCopy.current.text("检查器内容", "Inspector Content"), selection: $model.inspectorTab) {
                ForEach(SSHTerminalInspectorTab.allCases) { tab in Text(tab.title).tag(tab) }
            }.pickerStyle(.segmented).labelsHidden().padding(10)
                .accessibilityIdentifier("sshInspectorTabs")
            Divider()
            switch model.inspectorTab {
            case .scripts: SSHShellScriptsView(workspace: model)
            case .connection: SSHTerminalConnectionInfoView(model: model)
            }
        }
        .background(colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
    }
}

private struct SSHTerminalConnectionInfoView: View {
    @Bindable var model: SSHTerminalWorkspace
    private func text(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("连接信息", "Connection Info")).font(.headline)
                Spacer()
                Button { if let profile = model.inspectedProfile { model.editServer(profile) } } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help(text("编辑连接", "Edit connection"))
                    .disabled(!model.accounts.profiles.contains { $0.id == model.inspectedProfile?.id })
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let profile = model.inspectedProfile {
                        section(text("服务器", "Server")) {
                            value(text("名称", "Name"), profile.name)
                            value(text("地址", "Host"), profile.host)
                            value(text("端口", "Port"), String(profile.port))
                            value(text("用户", "User"), profile.username)
                        }
                        section(text("认证", "Authentication")) {
                            value(text("方式", "Method"), authentication(profile.authenticationMethod))
                            if let route = try? SSHConnectionStore.route(to: profile, in: model.accounts.profiles), !route.isEmpty {
                                value(text("跳板机", "Jump hosts"), route.map(\.name).joined(separator: " → "))
                            }
                            Text(text("服务器指纹", "Host fingerprint")).foregroundStyle(.secondary)
                            Text(profile.hostFingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if let session = model.current {
                            section(text("会话", "Session")) {
                                value(text("状态", "Status"), session.status)
                                value(text("终端尺寸", "Terminal size"), String(session.columns) + " × " + String(session.rows))
                            }
                        }
                        section(text("MCP 授权", "MCP Access")) {
                            Text(SSHAccess.current(id: profile.id, policy: model.accounts.policy).title)
                            if !model.accounts.policy.enabled { Text(text("MCP 当前未启用", "MCP is currently disabled")).foregroundStyle(.secondary) }
                            Text(text("在设置 → MCP → 连接权限中管理。", "Manage in Settings → MCP → Connection access.")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(text("选择服务器以查看连接信息。", "Select a server to view connection details.")).foregroundStyle(.secondary)
                    }
                }.font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityIdentifier("sshConnectionInspector")
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func value(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func authentication(_ method: SSHAuthentication) -> String {
        switch method {
        case .password: text("密码", "Password")
        case .privateKey: text("私钥", "Private key")
        case .agent: "SSH Agent"
        }
    }
}
