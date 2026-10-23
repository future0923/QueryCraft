import SwiftUI

/// The same persisted account grants as SSH Servers. Global MCP edits remain a separate draft.
struct MCPSSHAccessSection: View {
    @State private var model: SSHSettingsModel
    @State private var editing: SSHConnection?
    init(directory: URL) { _model = State(initialValue: SSHSettingsModel(service: SSHConnectionService(directory: directory))) }
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        Section(copy("SSH 服务器授权", "SSH server access")) {
            Text(copy("与“SSH 服务器”共用同一份授权，在任一入口保存后同步生效，无需重复配置。下方修改单独保存，不会提交其他未保存的 MCP 设置。", "Shared with SSH Servers. Save in either view; no duplicate setup. Access changes save separately from other unsaved MCP settings."))
                .font(MCPSettingsType.detail).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
            if model.loaded && model.profiles.isEmpty {
                Text(copy("暂无 SSH 服务器，请先在“SSH 服务器”中添加账号。", "No SSH accounts. Add one in SSH Servers first.")).foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name)
                        Text("\(profile.username)@\(profile.host):\(profile.port)")
                            .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                        Text(SSHAccess.current(id: profile.id, policy: model.policy).title)
                            .font(MCPSettingsType.detail).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copy("配置授权…", "Configure access…")) { editing = profile }.disabled(model.busy)
                }
            }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(height: 180)
            HStack {
                ProgressView().controlSize(.small).frame(width: 16).opacity(model.busy ? 1 : 0)
                Text(model.error ?? model.status).font(MCPSettingsType.detail).foregroundStyle(model.error == nil ? Color.secondary : .red)
                Spacer()
                if model.error != nil { Button(copy("重试", "Retry")) { Task { await model.load() } } }
            }.frame(minHeight: 24)
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: SSHConnectionService.settingsChanged)) { _ in Task { await model.load() } }
        .sheet(item: $editing, onDismiss: { Task { await model.load() } }) { profile in
            SSHAccessEditor(profile: profile, service: model.service)
        }
    }
}

struct SSHAccessEditor: View {
    let profile: SSHConnection
    let service: SSHConnectionService
    @Environment(\.dismiss) private var dismiss
    @State private var original: SSHAccountAccess?
    @State private var access = SSHAccess.denied
    @State private var fileRead = false
    @State private var fileTransfer = false
    @State private var fileManagement = false
    @State private var error: String?
    @State private var busy = false
    @State private var reloadRevision = 0
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        VStack(spacing: 0) {
            Text(copy("SSH 授权 · ", "SSH access · ") + profile.name).font(.headline).padding(20)
            Form {
                SSHAccessControls(access: $access, fileRead: $fileRead, fileTransfer: $fileTransfer, fileManagement: $fileManagement)
            }.formStyle(.grouped).disabled(busy || original == nil)
            Divider()
            HStack {
                Text(error ?? "").font(.caption).foregroundStyle(.red)
                Spacer()
                if error != nil { Button(copy("重新加载", "Reload")) { reloadRevision += 1 }.disabled(busy) }
                Button(copy("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(copy("保存授权", "Save access")) { Task { await save() } }
                    .buttonStyle(.borderedProminent).disabled(busy || original == nil)
            }.padding(16)
        }.frame(width: 540, height: 480)
        .task(id: reloadRevision) {
            busy = true; defer { busy = false }
            do {
                let snapshot = try await service.snapshot()
                let value = SSHAccountAccess(id: profile.id, policy: snapshot.policy)
                fileManagement = value.fileManagement
                error = nil; original = value; access = value.access; fileRead = value.fileRead; fileTransfer = value.fileTransfer
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() async {
        guard let original, !busy else { return }; busy = true; defer { busy = false }
        var value = original; value.access = access; value.fileRead = fileRead; value.fileTransfer = fileTransfer; value.fileManagement = fileManagement
        do { try await service.updateAccess(profile, expecting: original, value: value); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct SSHAccessControls: View {
    @Binding var access: SSHAccess
    @Binding var fileRead: Bool
    @Binding var fileTransfer: Bool
    @Binding var fileManagement: Bool
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        Section(copy("MCP 授权", "MCP access")) {
            Picker(copy("允许的操作", "Allowed operations"), selection: $access) {
                ForEach(SSHAccess.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle(copy("允许浏览和读取远程文件", "Allow browsing and reading remote files"), isOn: $fileRead).disabled(access == .denied)
            Toggle(copy("允许上传和下载文件", "Allow file uploads and downloads"), isOn: $fileTransfer).disabled(access == .denied)
            Toggle(copy("允许创建、移动和删除文件/空目录", "Allow creating, moving and deleting files or empty directories"), isOn: $fileManagement).disabled(access == .denied)
            Text(copy("与 MCP 连接权限页双向同步。文件权限单独授权；下载同时需要读取和传输权限。执行命令、传输及文件管理仍受全局完整访问和逐次确认约束。", "Shared with MCP Connections. File grants are independent; downloads need read and transfer access. Commands, transfers and file management still require global Full access and per-call confirmation."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
