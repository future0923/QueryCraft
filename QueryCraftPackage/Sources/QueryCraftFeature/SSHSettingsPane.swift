import SwiftUI
import UniformTypeIdentifiers

struct SSHSettingsPane: View {
    @Bindable var model: SSHSettingsModel
    @State private var draft: SSHConnectionDraft?
    @State private var removing: SSHConnection?
    @State private var importing = false
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    SettingsControlLabel(title: copy("SSH 服务器与账号", "SSH servers and accounts"),
                        description: copy("密码保存在本机钥匙串。每条连接使用独立账号与 MCP 权限。", "Passwords stay in the local Keychain. Each connection has its own account and MCP access."))
                    Spacer()
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(copy("重新加载", "Reload")).disabled(model.busy)
                    Button(copy("导入…", "Import…"), systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(!model.loaded || model.busy)
                    Button(copy("添加服务器", "Add server"), systemImage: "plus") { draft = SSHConnectionDraft(policy: model.policy) }
                        .disabled(!model.loaded || model.busy)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).frame(width: 16).opacity(model.busy ? 1 : 0)
                    Text(model.error ?? model.status).font(.caption)
                        .foregroundStyle(model.error == nil ? Color.secondary : .red)
                    Spacer()
                }.frame(height: 30)
            }
            Section(copy("已保存的连接", "Saved connections")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.loaded && model.profiles.isEmpty {
                            Text(copy("尚未添加服务器。点击“添加服务器”填写地址和账号。", "No servers yet. Choose Add server to enter an address and account."))
                                .foregroundStyle(.secondary).padding(.vertical, 12)
                        } else {
                            ForEach(model.filtered) { profile in
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack").font(.title2).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.name).font(.headline)
                                        Text("\(profile.username)@\(profile.host):\(profile.port)").textSelection(.enabled)
                                            .font(.subheadline).foregroundStyle(.secondary)
                                        Text(SSHAccess.current(id: profile.id, policy: model.policy).title + " · "
                                             + authenticationTitle(profile.authenticationMethod) + (profile.jumpConnectionID == nil ? "" : copy(" · 经跳板机", " · via jump host")))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Button(copy("配置", "Configure")) { draft = SSHConnectionDraft(profile: profile, policy: model.policy) }
                                    Button(role: .destructive) { removing = profile } label: { Image(systemName: "trash") }
                                        .help(copy("删除连接", "Delete connection"))
                                }.padding(.vertical, 7).disabled(model.busy)
                            }
                            if model.loaded && model.filtered.isEmpty && !model.profiles.isEmpty {
                                Text(copy("没有匹配的服务器。", "No matching servers.")).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(height: 220)
            }
            Section(copy("MCP 使用条件", "MCP requirements")) {
                Text(copy("在“插件”中安装 SSH 插件，再在此配置账号和授权。在 MCP 设置中启用 MCP；执行命令还要求全局上限为“完整访问”，并确认具体命令。", "Install SSH in Plugins, then configure accounts and access here. Enable MCP in its settings. Commands also require the Full access global limit and confirmation of the exact command."))
                    .font(.caption).foregroundStyle(.secondary)
                if !model.policy.enabled || model.policy.mode != .fullAccess {
                    Label(copy("当前 MCP 未启用或全局上限不允许执行命令；连接测试不受本机 MCP 开关限制。", "MCP is disabled or its global limit prevents commands. Local connection tests remain available."), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
        .searchable(text: $model.search, prompt: copy("搜索服务器或账号", "Search servers or accounts"))
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: SSHConnectionService.settingsChanged)) { _ in Task { await model.load() } }
        .sheet(item: $draft, onDismiss: { Task { await model.load() } }) { value in
            SSHConnectionEditor(draft: value, service: model.service)
        }
        .sheet(isPresented: $importing, onDismiss: { Task { await model.load() } }) { SSHConfigImportPane(service: model.service) }
        .confirmationDialog(copy("删除 SSH 连接？", "Delete SSH connection?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { profile in
            Button(copy("删除连接及凭据", "Delete connection and credential"), role: .destructive) {
                removing = nil; Task { await model.remove(profile) }
            }
        } message: { profile in Text(copy("将删除 \(profile.name) 的本地账号配置、保存的凭据和 MCP 授权。已提交的远程命令可能继续执行。", "Remove the local account, saved credential and MCP access for \(profile.name). A submitted remote command may continue running.")) }
    }
    private func authenticationTitle(_ value: SSHAuthentication) -> String {
        switch value { case .password: copy("密码", "Password"); case .privateKey: copy("私钥", "Private key"); case .agent: "SSH agent" }
    }
}

struct SSHConnectionEditor: View {
    @Bindable var draft: SSHConnectionDraft
    let service: SSHConnectionService
    @Environment(\.dismiss) private var dismiss
    @State private var selectingKey = false
    @State private var jumpProfiles: [SSHConnection] = []
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
                SSHAccessControls(access: $draft.access, fileRead: $draft.fileRead, fileTransfer: $draft.fileTransfer, fileManagement: $draft.fileManagement)
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
            await draft.synchronizeAccess(service: service)
        }
        .onDisappear { operation?.cancel(); draft.secret = "" }
        .interactiveDismissDisabled(draft.busy)
        .fileImporter(isPresented: $selectingKey, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { draft.keyPath = url.path }
        }
    }
}
