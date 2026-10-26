import SwiftUI

struct MCPSettingsPane: View {
    private let openSSH: (() -> Void)?
    @State private var model: MCPSettingsModel
    @State private var confirmUninstall = false
    @State private var showsSettingsIndex = false
    @State private var showsReview = false
    @State private var pendingIndexDestination: MCPSettingsDestination?
    @State private var reviewPolicy = MCPPolicy()

    init(model: MCPSettingsModel, openSSH: (() -> Void)? = nil) {
        _model = State(initialValue: model)
        self.openSSH = openSSH
    }

    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                settingsHeader(compact: false)
                settingsHeader(compact: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20).padding(.top, 8)

            Group {
                if model.section == "activity" {
                    MCPActivitySettingsPane(model: model)
                } else if model.section == "permissions" {
                    MCPPermissionsSettingsPane(model: model)
                } else {
                    accessPane
                }
            }
            .disabled(model.isBusy || !model.didLoad)

            Divider()
            HStack(spacing: 10) {
                Button { showsSettingsIndex = true } label: {
                    Label(copy("全部设置", "All settings"), systemImage: "list.bullet")
                }
                .buttonStyle(.bordered).fixedSize()
                .disabled(!model.didLoad || model.isBusy)
                .accessibilityIdentifier("mcp.settings.index.open")
                .help(copy("全部设置", "All settings"))
                ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(isWorking ? 1 : 0)
                    .accessibilityLabel(copy("正在处理", "Working"))
                    .accessibilityHidden(!isWorking)
                Group {
                    if let progress = model.installationProgress {
                        MCPInstallationProgressView(progress: progress)
                    } else {
                        Text(feedback)
                            .font(MCPSettingsType.detail).foregroundStyle(model.error == nil && model.runtimeError == nil ? Color.secondary : .red)
                            .lineLimit(2).textSelection(.enabled)
                            .help(feedback)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await model.recheck() } } label: {
                    Text(copy("重新检查", "Check again"))
                }.buttonStyle(.bordered).fixedSize().disabled(model.isBusy || model.isLoading || model.isCheckingRuntime)
                Button { beginReview() } label: { Text(copy("检查并保存", "Review and save")) }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.isBusy || !model.didLoad)
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
        }
        .font(MCPSettingsType.body)
        .controlSize(.regular)
        .task { await model.activate() }
        .task(id: model.section) { if model.section == "activity" { await model.loadHistory() } }
        .confirmationDialog(copy("卸载 MCP 程序？连接和权限设置将保留。", "Uninstall MCP? Connections and permissions are preserved."), isPresented: $confirmUninstall) {
            Button(copy("卸载", "Uninstall"), role: .destructive) { Task { await model.uninstall() } }
        }
        .sheet(isPresented: $showsSettingsIndex, onDismiss: {
            guard let destination = pendingIndexDestination else { return }
            pendingIndexDestination = nil
            if destination == .review { beginReview() }
            else { model.navigate(to: destination) }
        }) {
            MCPSettingsIndexView { destination in
                pendingIndexDestination = destination
                showsSettingsIndex = false
            }
        }
        .sheet(item: $model.scopeEditorConnection) { profile in
            MCPConnectionScopeEditor(model: model, profile: profile)
        }
        .sheet(isPresented: $showsReview) {
            MCPSettingsReviewView(policy: reviewPolicy, profiles: model.profiles, groups: model.groups) {
                guard model.policy == reviewPolicy else {
                    model.error = copy("配置已变化，请重新检查后保存。", "Settings changed. Review them again before saving.")
                    return
                }
                model.save()
            }
        }
    }

    private func settingsHeader(compact: Bool) -> some View {
        Picker(copy("MCP 设置", "MCP settings"), selection: Binding(
            get: { model.selectedSettingsPage }, set: { model.selectSettingsPage($0) })) {
            Text(copy("接入", "Setup")).tag("access")
            Text(compact ? copy("连接", "Access") : copy("连接权限", "Connections")).tag("connections")
            Text(compact ? copy("工具", "Tools") : copy("工具开关", "Tools")).tag("tools")
            Text(compact ? copy("执行", "Limits") : copy("执行限制", "Limits")).tag("execution")
            Text(compact ? copy("性能", "Perf.") : copy("发现与性能", "Performance")).tag("tuning")
            Text(compact ? copy("记录", "Logs") : copy("调用记录", "Activity")).tag("activity")
        }
        .pickerStyle(.segmented).labelsHidden()
        .controlSize(compact ? .small : .regular)
        .font(compact ? .system(size: 11) : MCPSettingsType.body)
        .fixedSize()
    }

    private var accessPane: some View {
        ScrollViewReader { proxy in
            Form { accessSections }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8, for: .scrollContent)
                .task(id: model.settingsNavigationRevision) {
                    if model.section == "access", let target = model.settingsScrollTarget {
                        await Task.yield()
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
        }
    }

    private func beginReview() {
        model.captureQueryTimeout()
        do {
            try model.policy.validate()
            model.error = nil
            reviewPolicy = model.policy
            showsReview = true
        } catch { model.error = error.localizedDescription }
    }

    private var isWorking: Bool { model.isBusy || model.isLoading || model.isCheckingRuntime }
    private var feedback: String { model.error ?? model.runtimeError ?? model.status }
    private var runtimeDescription: String {
        if let version = model.installedVersion {
            if model.availableVersion == version {
                return copy("已安装 \(version) · 已是最新", "Version \(version) installed · Up to date")
            }
            return copy("已安装 \(version)", "Version \(version) installed")
        }
        if model.runtimeError != nil { return copy("检查失败，请重新检查", "Check failed; try again") }
        return model.runtimeStatusLoaded ? copy("尚未安装", "Not installed") : copy("正在检查…", "Checking…")
    }

    @ViewBuilder private var accessSections: some View {
        if let openSSH {
            Section(copy("SSH 服务器", "SSH servers")) {
                SettingsControlLabel(title: copy("服务器账号与授权", "Server accounts and access"),
                    description: copy("先在插件页安装 SSH，再配置服务器、密码或私钥，以及每个账号的 MCP 权限。", "Install SSH in Plugins, then configure servers, passwords or private keys, and per-account MCP access."))
                Button(copy("管理 SSH 服务器…", "Manage SSH servers…"), action: openSSH)
            }
        }
        Section {
            Toggle(isOn: $model.policy.enabled) {
                MCPSettingsControlLabel(title: copy("启用 MCP", "Enable MCP"),
                    description: copy("让 AI 客户端访问你授权的数据库与 SSH 服务器。", "Let AI clients access authorized databases and SSH servers."))
            }
            .toggleStyle(.switch)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    MCPSettingsControlLabel(title: copy("MCP 程序", "MCP runtime"), description: runtimeDescription)
                    if model.runtimeUpdateAvailable, let version = model.availableVersion {
                        Label(copy("可升级至 \(version)", "Update available: \(version)"), systemImage: "arrow.up.circle.fill")
                            .font(MCPSettingsType.detail).foregroundStyle(Color.accentColor)
                    }
                }
                Spacer(minLength: 8)
                if model.runtimeUpdateAvailable { runtimeInstallButton.buttonStyle(.borderedProminent) }
                else { runtimeInstallButton }
                if model.installedVersion != nil {
                    Button(copy("卸载…", "Uninstall…"), role: .destructive) { confirmUninstall = true }
                        .disabled(model.isCheckingRuntime)
                }
            }
            HStack {
                MCPSettingsControlLabel(title: copy("已保存的密码", "Saved credentials"),
                    description: copy("一次授权已选连接，主程序与 MCP 共用安全凭据助手。", "Authorize selected connections once through the shared secure credential helper."))
                Spacer(minLength: 8)
                Button { Task { await model.authorizeCredentials() } } label: {
                    Text(copy("授权…", "Authorize…"))
                }
                    .disabled(model.installedVersion == nil || !model.policy.enabled)
            }
        } footer: {
            Text(copy("安装后可在 QueryCraft 退出时独立运行。请在“连接权限”中选择允许的连接。", "Works after QueryCraft quits. Choose allowed connections in Connections."))
        }
        .id("access-runtime")

        Section(copy("连接客户端", "Connect a client")) {
            Picker(copy("客户端", "Client"), selection: $model.client) {
                ForEach(MCPClientConfiguration.clients, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
            Picker(copy("连接方式", "Transport"), selection: $model.transport) {
                Text(copy("本地进程（stdio）", "Local process (stdio)")).tag("stdio")
                Text(copy("HTTP 服务", "HTTP service")).tag("http")
            }.pickerStyle(.menu)
            if MCPClientRegistration.supports(model.client) {
                clientRegistrationControls
            }
            HStack(alignment: .top) {
                Text(MCPClientConfiguration.guidance(model.client)).font(MCPSettingsType.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { model.copyConfiguration() } label: {
                    Text(copy("复制配置", "Copy configuration"))
                }
                    .disabled(model.installedVersion == nil || (model.transport == "http" && !MCPClientConfiguration.supportsHTTP(model.client)))
            }
            ScrollView([.horizontal, .vertical]) {
                Text(model.configuration).font(.body.monospaced())
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(height: configurationPreviewHeight, alignment: .topLeading)
                .accessibilityLabel(copy("客户端配置", "Client configuration"))
        }
        .task(id: model.didLoad ? model.client + model.configuration : "") {
            if model.didLoad { await model.inspectClientRegistration() }
        }
        .id("access-client")
        if model.transport == "http" || model.showsHTTPSettings { httpSection.id("access-http") }
        skillSection.id("access-skill")
        Section(copy("使用帮助", "Getting started")) {
            Text(copy("安装并启用 MCP，在“连接权限”中授权连接后保存。选择客户端后点击“一键添加”并重新连接；本地进程由客户端自动启动，HTTP 服务需在此启动。不支持自动配置的客户端可复制配置。", "Install and enable MCP, authorize connections in Connections, then save. Select a client, click Add to client and reconnect. Clients start the local process automatically; start HTTP here. Copy configuration for other clients."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
        }
        .id("access-help")
    }

    private var runtimeInstallButton: some View {
        Button {
            Task { await model.install() }
        } label: {
            if model.installedVersion == nil { Text(copy("安装…", "Install…")) }
            else if model.runtimeUpdateAvailable, let version = model.availableVersion {
                Text(copy("升级至 \(version)…", "Update to \(version)…"))
            } else { Text(copy("修复 / 重新安装…", "Repair / Reinstall…")) }
        }.disabled(model.isCheckingRuntime)
    }

    private var configurationPreviewHeight: CGFloat {
        let lines = model.configuration.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(6, max(3, lines)) * 16 + 4)
    }

    private var clientRegistrationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(copy("客户端配置", "Client configuration"))
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    .opacity(model.clientRegistrationChecking ? 1 : 0)
                Spacer(minLength: 4)
                Button(copy("一键移除", "Remove")) {
                    Task { await model.changeClientRegistration(adding: false) }
                }.disabled(model.clientRegistration?.state != .registered)
                Button(copy("一键添加", "Add to client")) {
                    Task { await model.changeClientRegistration(adding: true) }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.installedVersion == nil || model.clientRegistration == nil || model.clientRegistration?.state == .conflict)
            }
            Text(model.clientRegistration?.file.path ?? " ")
                .font(MCPSettingsType.detail.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(model.clientRegistration?.file.path ?? "")
            Text(clientRegistrationDescription)
                .font(MCPSettingsType.detail).foregroundStyle(model.clientRegistrationError == nil ? Color.secondary : .red)
                .lineLimit(2, reservesSpace: true).textSelection(.enabled).help(clientRegistrationDescription)
        }
    }

    private var clientRegistrationDescription: String {
        if let error = model.clientRegistrationError { return error }
        switch model.clientRegistration?.state {
        case .conflict: return copy("同名配置有修改，已保留。请在客户端检查。", "An existing entry differs; it has been preserved. Review it in your client.")
        case .registered: return copy("已添加；重复添加可更新连接方式。移除只删除 QueryCraft 这一项。", "Added. Add again to update the transport. Remove deletes only QueryCraft's entry.")
        case .absent: return copy("添加到此客户端的用户配置，自动备份并保留其他设置。", "Add to this client's user configuration, with a backup; other settings are preserved.")
        case nil: return copy("正在检查客户端配置…", "Checking client configuration…")
        }
    }

    private var httpSection: some View {
        Section(copy("HTTP 服务", "HTTP service")) {
            Toggle(isOn: Binding(get: { model.httpRunning }, set: { running in Task { await model.setHTTPRunning(running) } })) {
                MCPSettingsControlLabel(title: copy("运行 HTTP 服务", "Run HTTP service"),
                    description: model.httpRunning ? copy("运行中", "Running") : copy("已停止", "Stopped"))
            }
            .toggleStyle(.switch)
            .disabled(!model.httpRunning && (!model.policy.enabled || model.installedVersion == nil))
            LabeledContent(copy("服务地址", "Endpoint")) {
                Text(model.policy.http.endpoint).font(MCPSettingsType.detail.monospaced()).textSelection(.enabled)
            }
            Group {
                TextField(copy("主机", "Host"), text: $model.policy.http.host)
                TextField(copy("端口", "Port"), value: $model.policy.http.port, format: .number.grouping(.never))
                TextField(copy("路径", "Path"), text: $model.policy.http.path)
                Toggle(copy("允许远程访问", "Allow remote access"), isOn: $model.policy.http.allowsRemote)
                TextField(copy("允许的主机", "Allowed Hosts"), text: Binding(get: { model.policy.http.allowedHosts.joined(separator: ", ") }, set: { model.policy.http.allowedHosts = split($0) }))
                TextField(copy("允许的来源", "Allowed Origins"), text: Binding(get: { model.policy.http.allowedOrigins.joined(separator: ", ") }, set: { model.policy.http.allowedOrigins = split($0) }))
                SecureField(copy("访问令牌", "Bearer token"), text: $model.policy.http.token)
                HStack {
                    Button(copy("轮换令牌", "Rotate token")) { model.policy.http.token = UUID().uuidString + UUID().uuidString; model.save() }
                    Spacer()
                    Button(copy("保存并启动 / 重启", "Save and start / restart")) { Task { await model.setHTTPRunning(true) } }
                        .disabled(!model.policy.enabled || model.installedVersion == nil)
                }
            }
        }
    }

    private var skillSection: some View {
        Section(copy("可选 \(model.serverIdentity.displayName) Skill", "Optional \(model.serverIdentity.displayName) skill")) {
            Group {
                Text(skillFeedback)
                    .font(MCPSettingsType.detail)
                    .foregroundStyle(model.skillError == nil && model.componentError == nil ? Color.secondary : .red)
                    .lineLimit(2, reservesSpace: true).help(skillFeedback)
                Picker(copy("安装位置", "Destination"), selection: $model.skillTarget) {
                    ForEach(MCPSkillTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Text(model.skillDirectory.path).font(MCPSettingsType.detail.monospaced()).textSelection(.enabled)
                LabeledContent(copy("状态", "Status"), value: skillStatusText)
                HStack {
                    Spacer()
                    Button(copy("卸载", "Uninstall"), role: .destructive) { Task { await model.changeSkillInstallation(install: false) } }
                        .disabled(model.skillStatus == nil || model.skillStatus == .notInstalled || model.skillStatus == .modified)
                    Button(model.skillStatus == .notInstalled ? copy("安装 Skill…", "Install skill…") : copy("更新 Skill…", "Update skill…")) {
                        Task { await model.changeSkillInstallation(install: true) }
                    }.disabled(model.skillStatus == nil || model.skillStatus == .modified || model.skillStatus == .current)
                }
            }
        }.task(id: model.skillTarget) { await model.inspectSkill() }
    }

    private var skillFeedback: String {
        let errors = [model.skillError, model.componentError].compactMap { $0 }
        if !errors.isEmpty { return errors.joined(separator: "\n") }
        if model.checkingComponents { return copy("正在检查独立组件目录…", "Checking component catalogs…") }
        return copy("为支持 Skill 的客户端补充数据库工作流；MCP 可独立使用。", "Adds database workflows for clients that support skills. MCP works independently.")
    }

    private var skillStatusText: String {
        switch model.skillStatus {
        case .notInstalled: copy("未安装", "Not installed")
        case .current: copy("已安装 \(model.installedSkillVersion ?? "")", "Installed \(model.installedSkillVersion ?? "")")
        case .updateAvailable: copy("可更新到 \(model.availableSkillVersion ?? "")", "Update available: \(model.availableSkillVersion ?? "")")
        case .modified: copy("含本地修改，已保留文件", "Local changes preserved")
        case nil: copy("正在检查…", "Checking…")
        }
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct MCPInstallationProgressView: View {
    let progress: MCPComponentInstallationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(progress.phase.title)
                Spacer(minLength: 0)
                if let detail = progress.detail { Text(detail).monospacedDigit() }
            }
            .font(MCPSettingsType.detail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel(progress.phase.title)
        }
        .help([progress.phase.title, progress.detail].compactMap { $0 }.joined(separator: " "))
    }
}
