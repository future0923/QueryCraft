import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class SSHConfigImportModel {
    var path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config").path
    var preview: SSHConfigPreview?
    private(set) var loadedPath: String?
    var selection: String?
    var profiles: [SSHConnection] = []
    var policy = MCPPolicy()
    var busy = false
    var error: String?
    private var generation = UUID()
    var selected: SSHConfigCandidate? { preview?.candidates.first { $0.id == selection } }
    var cannotImport: String? {
        guard let candidate = selected else { return nil }
        if candidate.blocked { return AppCopy.current.text("此配置包含无法兼容的规则，请手动配置。", "Unsupported rules require manual configuration.") }
        if profiles.contains(where: { $0.name == candidate.endpoint.alias && candidate.endpoint.matches($0) }) {
            return AppCopy.current.text("此别名已保存，请在服务器列表配置。", "This alias is already saved. Configure it in the server list.")
        }
        do { _ = try candidate.jumpID(in: profiles); return nil }
        catch { return error.localizedDescription }
    }
    func load(service: SSHConnectionService) async {
        let token = UUID(); generation = token; busy = true
        let path = path
        if loadedPath != path { preview = nil; selection = nil }
        do {
            // Bounded local file I/O stays off the main/cooperative executors.
            let result: SSHConfigPreview = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try SSHConfigImporter().preview(path: path)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            let snapshot = try await service.snapshot()
            try Task.checkCancellation(); guard generation == token else { return }
            preview = result; loadedPath = path; profiles = snapshot.profiles; policy = snapshot.policy; error = nil
            if !result.candidates.contains(where: { $0.id == selection }) { selection = result.candidates.first?.id }
        } catch is CancellationError {} catch { if generation == token { self.error = error.localizedDescription } }
        if generation == token { busy = false }
    }
    func refreshAccounts(service: SSHConnectionService) async {
        do { let snapshot = try await service.snapshot(); profiles = snapshot.profiles; policy = snapshot.policy }
        catch { self.error = error.localizedDescription }
    }
    func draft() throws -> SSHConnectionDraft {
        guard let candidate = selected, cannotImport == nil else { throw MCPFailure("Review the selected SSH alias before importing.") }
        let draft = SSHConnectionDraft(policy: policy)
        draft.name = candidate.endpoint.alias; draft.host = candidate.endpoint.host; draft.port = String(candidate.endpoint.port)
        draft.username = candidate.endpoint.username; draft.authentication = candidate.authentication
        draft.keyPath = candidate.keyPath ?? ""; draft.agentSocketPath = candidate.agentSocketPath ?? ""
        draft.keyHasPassphrase = false; draft.jumpConnectionID = try candidate.jumpID(in: profiles)
        // Imported files never authorize an account or establish host trust.
        draft.verifiedHost = false; draft.fingerprint = ""
        return draft
    }
}

struct SSHConfigImportPane: View {
    let service: SSHConnectionService
    @State var model = SSHConfigImportModel()
    @State private var choosingFile = false
    @State private var draft: SSHConnectionDraft?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private func authenticationTitle(_ value: SSHAuthentication) -> String {
        switch value { case .password: copy("密码", "Password"); case .privateKey: copy("私钥", "Private key"); case .agent: "SSH agent" }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(copy("导入 SSH 配置", "Import SSH configuration")).font(.headline); Spacer() }.padding(20)
            HStack {
                TextField("~/.ssh/config", text: $model.path).textFieldStyle(.roundedBorder)
                Button(copy("选择…", "Choose…")) { choosingFile = true }
                Button(copy("读取预览", "Load preview")) { operation = Task { await model.load(service: service) } }
            }.padding(.horizontal, 20).disabled(model.busy)
            Text(copy("只导入连接信息。先配置并保存跳板机，再导入依赖它的目标；每个账号仍需核对指纹和授权。配置中的外部命令不会执行。", "Import connection settings only. Save jump hosts before their targets; verify each fingerprint and grant. External commands in the configuration are never executed."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10)
            HSplitView {
                List(selection: $model.selection) {
                    if let preview = model.preview {
                        ForEach(preview.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.endpoint.alias).font(.headline)
                                Text(candidate.endpoint.host).font(.caption).foregroundStyle(.secondary)
                            }.tag(candidate.id)
                        }
                        if preview.candidates.isEmpty { Text(copy("未找到具体 Host 别名。", "No concrete Host aliases found.")).foregroundStyle(.secondary) }
                    }
                }.frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let candidate = model.selected {
                            LabeledContent(copy("主机", "Host"), value: candidate.endpoint.host)
                            LabeledContent(copy("端口", "Port"), value: String(candidate.endpoint.port))
                            LabeledContent(copy("账号", "User"), value: candidate.endpoint.username)
                            LabeledContent(copy("认证", "Authentication"), value: authenticationTitle(candidate.authentication))
                            if let key = candidate.keyPath { Text(key).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            if let socket = candidate.agentSocketPath { Text(socket).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            if !candidate.jumps.isEmpty {
                                Text(copy("跳板链", "Jump chain")).font(.headline)
                                ForEach(candidate.jumps, id: \.alias) { jump in
                                    Text("\(jump.alias) · \(jump.username)@\(jump.host):\(jump.port)").font(.caption)
                                }
                            }
                            ForEach(candidate.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            if let reason = model.cannotImport { Text(reason).font(.caption).foregroundStyle(.orange) }
                        }
                        if let preview = model.preview {
                            ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(minWidth: 300)
            }.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            HStack {
                ProgressView().controlSize(.small).frame(width: 16).opacity(model.busy ? 1 : 0)
                Text(model.error ?? "").font(.caption).foregroundStyle(.red).lineLimit(3)
                Spacer()
                Button(copy("关闭", "Close")) { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(copy("配置并添加", "Configure and add")) {
                    do { draft = try model.draft() } catch { model.error = error.localizedDescription }
                }.disabled(model.busy || model.selected == nil || model.cannotImport != nil)
            }.padding(16).frame(minHeight: 72)
        }.frame(width: 780, height: 650)
        .task { await model.load(service: service) }
        .onDisappear { operation?.cancel() }
        .sheet(item: $draft, onDismiss: { Task { await model.refreshAccounts(service: service) } }) { SSHConnectionEditor(draft: $0, service: service) }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .item]) { result in
            if case .success(let url) = result { model.path = url.path; operation = Task { await model.load(service: service) } }
        }
    }
}
