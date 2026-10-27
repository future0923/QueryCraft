import SwiftUI
import QueryCraftMobileCore

struct MobileConnectionForm: View {
    @Bindable var draft: MobileConnectionDraft
    let save: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("驱动", selection: $draft.driver) { ForEach(MobileDriver.allCases) { Text($0.title).tag($0) } }
                    if draft.driver == .elasticsearch {
                        Picker("认证", selection: $draft.authentication) { ForEach(MobileAuthentication.allCases) { Text($0.title).tag($0) } }
                    }
                } footer: { Text("MySQL、PostgreSQL 支持表数据编辑、SQL 写入和事务。Redis 支持键值编辑，Elasticsearch 支持文档与索引管理；Doris 提供只读浏览，Kafka 尚未移植。") }
                Section(draft.driver.title) {
                    TextField("连接名称", text: $draft.name)
                    TextField("服务器", text: $draft.host).textContentType(.URL)
                    TextField("端口", text: $draft.port).keyboardType(.numberPad)
                    if draft.authentication == .usernamePassword { TextField("用户名", text: $draft.username).textContentType(.username) }
                    if draft.authentication != .none { SecureField(draft.authentication == .apiKey ? "API Key（已编码）" : "密码", text: $draft.password).textContentType(.password) }
                    if draft.driver != .elasticsearch { TextField(draft.driver == .redis ? "逻辑数据库（默认 0）" : "数据库（可选）", text: $draft.database) }
                    if draft.driver == .postgresql { TextField("默认 Schema（可选）", text: $draft.schemaName) }
                    Picker("TLS", selection: $draft.tlsMode) {
                        Text("关闭").tag(ConnectionTLSMode.disabled)
                        if draft.driver != .redis { Text("必须加密（不验证身份）").tag(ConnectionTLSMode.required) }
                        if draft.driver == .elasticsearch || draft.driver == .postgresql {
                            Text("验证 CA").tag(ConnectionTLSMode.verifyCA)
                            Text("验证证书与主机名").tag(ConnectionTLSMode.verifyIdentity)
                        }
                    }
                    if draft.authentication != .none { Toggle("将密码保存到本机钥匙串", isOn: $draft.remembersPassword) }
                }
                Section {
                    Button("测试连接") { testConnection() }.disabled(draft.isTesting)
                    HStack {
                        ProgressView().opacity(draft.isTesting ? 1 : 0)
                        Text(draft.message ?? "凭据不会写入连接文件。Redis 当前不支持 TLS；Doris 提供只读浏览，Elasticsearch 写操作须预览并确认。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
            .disabled(draft.isTesting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(draft.driver.title + " 连接").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { do { try save() } catch { draft.message = error.localizedDescription } }.disabled(draft.isTesting)
                }
            }.onDisappear { testTask?.cancel(); draft.isTesting = false }
        }
    }
    private func testConnection() {
        do {
            let profile = try draft.profile(), password = draft.password
            draft.isTesting = true; draft.message = "正在连接…"
            testTask = Task {
                do {
                    switch profile.driver {
                    case .mysql: _ = try await MobileMariaDBExecutor().execute(configuration: profile.configuration(password: password), sql: "SELECT 1")
                    case .postgresql: _ = try await MobilePostgreSQLExecutor().execute(configuration: profile.configuration(password: password), sql: "SELECT 1")
                    case .doris: _ = try await MobileDorisExecutor().execute(configuration: profile.configuration(password: password), sql: "SELECT 1")
                    case .redis, .elasticsearch: try await MobileResourceService(profile: profile, password: password).test()
                    }
                    try Task.checkCancellation()
                    draft.message = "连接成功"
                } catch { if !(error is CancellationError) { draft.message = error.localizedDescription } }
                draft.isTesting = false; testTask = nil
            }
        } catch { draft.message = error.localizedDescription }
    }
}
