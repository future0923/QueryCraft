import SwiftUI

struct MCPSettingsPane: View {
    @State private var model: MCPSettingsModel
    @State private var confirmUninstall = false

    init(model: MCPSettingsModel) {
        _model = State(initialValue: model)
    }

    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            Picker(copy("MCP 设置", "MCP settings"), selection: $model.section) {
                Text(copy("接入", "Connection")).tag("access")
                Text(copy("访问权限", "Access")).tag("permissions")
                Text(copy("调用记录", "Activity")).tag("activity")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Group {
                if model.section == "activity" {
                    MCPActivitySettingsPane(model: model)
                } else if model.section == "permissions" {
                    MCPPermissionsSettingsPane(model: model)
                } else {
                    Form { accessSections }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 8, for: .scrollContent)
                }
            }
            .disabled(model.isBusy || !model.didLoad)

            Divider()
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(isWorking ? 1 : 0)
                    .accessibilityLabel(copy("正在处理", "Working"))
                    .accessibilityHidden(!isWorking)
                Text(feedback)
                    .font(MCPSettingsType.detail).foregroundStyle(model.error == nil && model.runtimeError == nil ? Color.secondary : .red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .help(feedback)
                Button { Task { await model.recheck() } } label: {
                    Text(copy("重新检查", "Check again"))
                }.buttonStyle(.bordered).disabled(model.isLoading || model.isCheckingRuntime)
                Button { model.save() } label: { Text(copy("保存", "Save")) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.didLoad)
            }
            .frame(height: 44)
            .padding(.horizontal, 16)
            .disabled(model.isBusy)
        }
        .font(MCPSettingsType.body)
        .controlSize(.regular)
        .task { await model.activate() }
        .task(id: model.section) { if model.section == "activity" { await model.loadHistory() } }
        .confirmationDialog(copy("卸载 MCP 程序？连接和权限设置将保留。", "Uninstall MCP? Connections and permissions are preserved."), isPresented: $confirmUninstall) {
            Button(copy("卸载", "Uninstall"), role: .destructive) { Task { await model.uninstall() } }
        }

    }

    private var isWorking: Bool { model.isBusy || model.isLoading || model.isCheckingRuntime }
    private var feedback: String { model.error ?? model.runtimeError ?? model.status }
    private var runtimeDescription: String {
        if let version = model.installedVersion { return copy("已安装 \(version)", "Version \(version) installed") }
        if model.runtimeError != nil { return copy("检查失败，请重新检查", "Check failed; try again") }
        return model.runtimeStatusLoaded ? copy("尚未安装", "Not installed") : copy("正在检查…", "Checking…")
    }

    @ViewBuilder private var accessSections: some View {
        Section {
            Toggle(isOn: $model.policy.enabled) {
                MCPSettingsControlLabel(title: copy("启用 MCP", "Enable MCP"),
                    description: copy("让 AI 客户端访问你授权的数据库。", "Let AI clients access the databases you authorize."))
            }
            .toggleStyle(.switch)
            HStack {
                MCPSettingsControlLabel(title: copy("MCP 程序", "MCP runtime"),
                    description: runtimeDescription)
                Spacer(minLength: 8)
                Button(model.installedVersion == nil ? copy("安装…", "Install…") : copy("升级 / 修复…", "Upgrade / Repair…")) {
                    Task { await model.install() }
                }.disabled(model.isCheckingRuntime)
                if model.installedVersion != nil {
                    Button(copy("卸载…", "Uninstall…"), role: .destructive) { confirmUninstall = true }
                        .disabled(model.isCheckingRuntime)
                }
            }
            HStack {
                MCPSettingsControlLabel(title: copy("已保存的密码", "Saved credentials"),
                    description: copy("首次接入时，允许独立程序读取钥匙串密码。", "Authorize Keychain access when connecting for the first time."))
                Spacer(minLength: 8)
                Button { Task { await model.authorizeCredentials() } } label: {
                    Text(copy("授权…", "Authorize…"))
                }
                    .disabled(model.installedVersion == nil || !model.policy.enabled)
            }
        } footer: {
            Text(copy("安装后可在 QueryCraft 退出时独立运行。请在“访问权限”中选择允许的连接。", "Works after QueryCraft quits. Choose allowed connections in Access."))
        }

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
        if model.transport == "http" { httpSection }
        skillSection
        advancedSection
        Section(copy("安装信息", "Installation details")) {
            LabeledContent(copy("可用组件版本", "Available component version"), value: model.availableVersion ?? (model.runtimeStatusLoaded ? copy("尚未获取", "Not checked") : copy("正在检查…", "Checking…")))
            Text(model.executable).font(MCPSettingsType.detail.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Section(copy("使用帮助", "Getting started")) {
            Text(copy("安装并启用 MCP，在“访问权限”中授权连接后保存。选择客户端后点击“一键添加”并重新连接；本地进程由客户端自动启动，HTTP 服务需在此启动。不支持自动配置的客户端可复制配置。", "Install and enable MCP, authorize connections in Access, then save. Select a client, click Add to client and reconnect. Clients start the local process automatically; start HTTP here. Copy configuration for other clients."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
        }
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
        Section(copy("可选 QueryCraft Skill", "Optional QueryCraft skill")) {
            Group {
                Text(copy("为支持 Skill 的客户端补充数据库工作流；MCP 可独立使用。", "Adds database workflows for clients that support skills. MCP works independently."))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
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
                Text(model.skillError ?? "").font(MCPSettingsType.detail).foregroundStyle(.red).lineLimit(3).frame(minHeight: 16, alignment: .leading)
            }
                Text(model.componentError ?? (model.checkingComponents ? copy("正在检查独立组件目录…", "Checking component catalogs…") : ""))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary).lineLimit(2).frame(height: 32, alignment: .leading)
        }.task(id: model.skillTarget) { await model.inspectSkill() }
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

    private var advancedSection: some View {
        Section(copy("高级设置", "Advanced settings")) {
            Group {
                Picker(copy("工具发现", "Tool discovery"), selection: Binding(get: { model.policy.tuning.discovery }, set: { value in model.updateOptimizations { $0.discovery = value } })) {
                    Text(copy("直接工具", "Direct tools")).tag(MCPToolDiscovery.flat)
                    Text(copy("按需发现", "Lazy discovery")).tag(MCPToolDiscovery.lazy)
                    Text(copy("两者同时", "Both")).tag(MCPToolDiscovery.both)
                }.pickerStyle(.menu)
                Text(copy("按需发现可减少工具上下文；保存后在客户端重新加载工具。", "Lazy discovery reduces tool context. Reload client tools after saving."))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                Stepper(copy("结构缓存：\(model.policy.tuning.metadataCacheSeconds) 秒", "Metadata cache: \(model.policy.tuning.metadataCacheSeconds) seconds"), value: Binding(get: { model.policy.tuning.metadataCacheSeconds }, set: { value in model.updateOptimizations { $0.metadataCacheSeconds = value } }), in: 0...300, step: 10)
                Stepper(copy("元数据空闲连接：\(model.policy.tuning.maximumIdleConnections)", "Idle metadata connections: \(model.policy.tuning.maximumIdleConnections)"), value: Binding(get: { model.policy.tuning.maximumIdleConnections }, set: { value in model.updateOptimizations { $0.maximumIdleConnections = value } }), in: 0...8)
                Text(copy("设为 0 关闭缓存或连接复用。查询结果、Redis 键和消息保持实时。", "Set to 0 to disable caching or reuse. Query results, Redis keys and messages stay live."))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                TextField(copy("最大结果行数", "Maximum rows"), value: $model.policy.maximumRows, format: .number.grouping(.never))
                TextField(copy("结果字节上限", "Maximum result bytes"), value: $model.policy.maximumResultBytes, format: .number.grouping(.never))
                TextField(copy("会话空闲超时（秒）", "Session idle timeout (seconds)"), value: $model.policy.sessionIdleSeconds, format: .number.grouping(.never))
                Stepper(copy("最多 \(model.policy.maximumSessions) 个会话", "Maximum \(model.policy.maximumSessions) sessions"), value: $model.policy.maximumSessions, in: 1...128)
            }
        }
    }

    private func split(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
