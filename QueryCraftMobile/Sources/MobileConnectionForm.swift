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
                Section("MySQL") {
                    TextField("连接名称", text: $draft.name)
                    TextField("服务器", text: $draft.host).textContentType(.URL)
                    TextField("端口", text: $draft.port).keyboardType(.numberPad)
                    TextField("用户名", text: $draft.username).textContentType(.username)
                    SecureField("密码", text: $draft.password).textContentType(.password)
                    TextField("数据库（可选）", text: $draft.database)
                    Picker("TLS", selection: $draft.tlsMode) {
                        Text("关闭").tag(ConnectionTLSMode.disabled)
                        Text("必须加密（不验证身份）").tag(ConnectionTLSMode.required)
                    }
                    Toggle("将密码保存到本机钥匙串", isOn: $draft.remembersPassword)
                }
                Section {
                    Button("测试连接") { testConnection() }.disabled(draft.isTesting)
                    HStack {
                        ProgressView().opacity(draft.isTesting ? 1 : 0)
                        Text(draft.message ?? "密码不会写入连接文件。SQL 查询保持只读，表数据修改由安全锁控制。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
            .disabled(draft.isTesting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("MySQL 连接").navigationBarTitleDisplayMode(.inline)
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
                    _ = try await MobileMariaDBExecutor().execute(configuration: profile.configuration(password: password), sql: "SELECT 1")
                    try Task.checkCancellation()
                    draft.message = "连接成功"
                } catch { if !(error is CancellationError) { draft.message = error.localizedDescription } }
                draft.isTesting = false; testTask = nil
            }
        } catch { draft.message = error.localizedDescription }
    }
}
