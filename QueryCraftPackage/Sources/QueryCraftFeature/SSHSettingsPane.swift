import SwiftUI
import UniformTypeIdentifiers

/// SSH account management is part of the welcome connection catalog. This
/// settings page retains the local Shell library only.
struct SSHSettingsPane: View {
    @State private var scripts: ShellScriptSettingsModel
    init(model _: SSHSettingsModel, scripts: ShellScriptSettingsModel? = nil) {
        _scripts = State(initialValue: scripts ?? ShellScriptSettingsModel())
    }
    var body: some View {
        Form {
            ShellScriptSettingsSection(model: scripts)
        }.formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
    }
}

struct SSHConnectionEditor: View {
    @Bindable var draft: SSHConnectionDraft
    let service: SSHConnectionService
    @Environment(\.dismiss) private var dismiss
    @State private var selectingKey = false
    @State private var jumpProfiles: [SSHConnection] = []
    @State private var groups: [ConnectionGroup] = []
    @State private var operation: Task<Void, Never>?
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.original == nil ? copy("添加 SSH 服务器", "Add SSH server") : copy("配置 SSH 服务器", "Configure SSH server"))
                    .font(.headline)
                Spacer()
            }.padding(20)
            Form {
                Section(copy("服务器", "Server")) {
                    TextField(copy("名称", "Name"), text: $draft.name)
                    Picker(copy("分组", "Group"), selection: $draft.groupID) {
                        Text(copy("未分组", "Ungrouped")).tag(Optional<UUID>.none)
                        ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField(copy("地址", "Host"), text: $draft.host)
                    TextField(copy("端口", "Port"), text: $draft.port)
                    TextField(copy("用户名", "Username"), text: $draft.username)
                    Picker(copy("跳板机", "Jump host"), selection: $draft.jumpConnectionID) {
                        Text(copy("直连", "Direct connection")).tag(Optional<UUID>.none)
                        ForEach(jumpProfiles.filter { $0.id != draft.id }) { profile in
                            Text(profile.name + " · " + profile.username + "@" + profile.host).tag(Optional(profile.id))
                        }
                    }
                    Text(copy("复用已保存账号，最多四跳；每一跳独立核对指纹和 MCP 连接授权。", "Use a saved account, up to four hops. Each hop has its own fingerprint and MCP connection grant."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(copy("账号认证", "Account authentication")) {
                    Picker(copy("认证方式", "Authentication"), selection: $draft.authentication) {
                        Text(copy("密码", "Password")).tag(SSHConnectionDraft.Authentication.password)
                        Text(copy("私钥", "Private key")).tag(SSHConnectionDraft.Authentication.privateKey)
                        Text("SSH agent").tag(SSHConnectionDraft.Authentication.agent)
                    }
                    if draft.authentication == .privateKey {
                        HStack {
                            TextField(copy("私钥绝对路径", "Absolute key path"), text: $draft.keyPath)
                            Button(copy("选择…", "Choose…")) { selectingKey = true }
                        }
                        Toggle(copy("私钥已加密，需要口令", "Private key requires a passphrase"), isOn: $draft.keyHasPassphrase)
                    }
                    if draft.authentication == .agent {
                        TextField(copy("Agent socket 绝对路径（可选）", "Absolute agent socket (optional)"), text: $draft.agentSocketPath,
                            prompt: Text("SSH_AUTH_SOCK"))
                        Text(copy("留空使用当前进程的 SSH_AUTH_SOCK。密钥由本机 agent 签名，不保存密码，也不向服务器转发 agent。", "Leave blank to use this process's SSH_AUTH_SOCK. The local agent signs; no password is saved and the agent is never forwarded."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.authentication == .password || (draft.authentication == .privateKey && draft.keyHasPassphrase) {
                        SecureField(draft.authentication == .password ? copy("密码", "Password") : copy("私钥口令", "Key passphrase"),
                            text: $draft.secret, prompt: Text(draft.retainsCredential ? copy("留空保留已保存的凭据", "Leave blank to keep the saved credential") : copy("输入后保存到钥匙串", "Saved to Keychain")))
                        Text(copy("凭据仅在本机录入与保存，MCP 根据连接 ID 取用。", "Credentials are entered and saved locally. MCP uses the connection ID to retrieve them."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(copy("服务器身份", "Server identity")) {
                    HStack {
                        TextField(copy("SHA256 指纹", "SHA256 fingerprint"), text: $draft.fingerprint)
                            .font(.system(.caption, design: .monospaced))
                        Button(copy("读取指纹", "Read fingerprint")) {
                            operation = Task { await draft.readFingerprint(service: service) }
                        }
                    }
                    Text(copy("读取结果尚未验证。请与服务器管理员或可信记录核对后确认；指纹不匹配时不会发送账号凭据。", "A scanned fingerprint is unverified. Compare it with your administrator or a trusted record before confirming. Credentials are not sent when the fingerprint differs."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(copy("已通过可信渠道核对该指纹", "I verified this fingerprint through a trusted channel"), isOn: $draft.verifiedHost)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
            .disabled(draft.busy)
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).frame(width: 16).opacity(draft.busy ? 1 : 0)
                Text(draft.error ?? draft.feedback).font(.caption).lineLimit(3)
                    .foregroundStyle(draft.error == nil ? Color.secondary : .red)
                Spacer(minLength: 4)
                Button(copy("测试连接", "Test")) { operation = Task { await draft.test(service: service) } }.disabled(draft.busy)
                Button(copy("取消", "Cancel")) { operation?.cancel(); draft.secret = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button(copy("保存", "Save")) {
                    operation = Task { if await draft.save(service: service) { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(draft.busy)
            }.padding(16).frame(minHeight: 76)
        }
        .frame(width: 620, height: 730)
        .onChange(of: draft.host) { draft.verifiedHost = false; draft.feedback = "" }
        .onChange(of: draft.port) { draft.verifiedHost = false; draft.feedback = "" }
        .onChange(of: draft.fingerprint) { draft.verifiedHost = false; draft.feedback = "" }
        .onChange(of: draft.jumpConnectionID) { draft.verifiedHost = false; draft.feedback = "" }
        .onChange(of: draft.agentSocketPath) { draft.feedback = "" }
        .onChange(of: draft.authentication) { draft.secret = ""; draft.feedback = "" }
        .onChange(of: draft.keyHasPassphrase) { draft.secret = ""; draft.feedback = "" }
        .onChange(of: draft.username) { draft.feedback = "" }
        .onChange(of: draft.secret) { draft.feedback = "" }
        .onChange(of: draft.keyPath) { draft.feedback = "" }
        .onReceive(NotificationCenter.default.publisher(for: SSHConnectionService.settingsChanged)) { _ in Task { await draft.synchronizeAccess(service: service) } }
        .task {
            if let snapshot = try? await service.snapshot() { jumpProfiles = snapshot.profiles }
            do { groups = try await service.connectionGroups() }
            catch { draft.error = error.localizedDescription }
            await draft.synchronizeAccess(service: service)
        }
        .onDisappear { operation?.cancel(); draft.secret = "" }
        .interactiveDismissDisabled(draft.busy)
        .fileImporter(isPresented: $selectingKey, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { draft.keyPath = url.path }
        }
    }
}
