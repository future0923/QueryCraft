import SwiftUI
import UniformTypeIdentifiers
import Observation

@MainActor @Observable
final class SSHPluginSettingsModel {
    let manager: SSHPluginManager
    var installed: String?
    var release: MCPComponentRelease?
    var checked = false
    var busy = false
    var progress: MCPComponentInstallationProgress?
    var error: String?
    var availabilityError: String?
    var status = ""
    init(manager: SSHPluginManager = .shared) { self.manager = manager }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { installed = try await manager.installedVersion(); error = nil }
        catch { self.error = error.localizedDescription }
        do { release = try await manager.available(); availabilityError = nil }
        catch is CancellationError {} catch { availabilityError = error.localizedDescription }
        checked = true
    }
    func install(source: URL? = nil) async {
        guard !busy else { return }; busy = true; error = nil; status = ""
        defer { busy = false; progress = nil }
        do {
            if let source {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                progress = .init(phase: .verifying)
                try await manager.importPackage(source)
            } else if let release {
                try await manager.install(release: release) { [weak self] value in await self?.record(value) }
            } else { throw MCPFailure("No compatible SSH release is available.") }
            installed = try await manager.installedVersion()
            status = AppCopy.current.text("安装完成，请重新连接 MCP 客户端。", "Installed. Reconnect MCP clients.")
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func record(_ value: MCPComponentInstallationProgress) { progress = value }
    func uninstall() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await manager.uninstall(); installed = nil; error = nil
            status = AppCopy.current.text("已卸载。连接和账号已保留，请重新连接 MCP 客户端。", "Uninstalled. Accounts were kept. Reconnect MCP clients.")
        } catch { self.error = error.localizedDescription }
    }
}

struct SSHPluginSettingsSection: View {
    @Bindable var model: SSHPluginSettingsModel
    var openServers: (() -> Void)? = nil
    @State private var importing = false
    @State private var confirmingRemoval = false
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        Section(copy("服务器插件", "Server plugins")) {
            HStack(spacing: 12) {
                Image(systemName: "terminal").font(.title2).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SSH · libssh2").font(.headline)
                    Text(model.installed.map { copy("已安装 \($0)", "Installed \($0)") }
                        ?? (model.checked ? copy("未安装", "Not installed") : copy("正在检查…", "Checking…")))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.busy { ProgressView().controlSize(.small).frame(width: 18) }
                Menu {
                    if let openServers {
                        Button(copy("管理服务器与账号…", "Manage servers and accounts…"), action: openServers)
                        Divider()
                    }
                    Button(copy("选择本地安装包…", "Choose local package…")) { importing = true }
                    Button(copy("下载并安装", "Download and install")) { Task { await model.install() } }
                        .disabled(model.release == nil)
                    if model.installed != nil {
                        Divider()
                        Button(copy("卸载", "Uninstall"), role: .destructive) { confirmingRemoval = true }
                    }
                } label: { Text(copy("管理", "Manage")) }
                .disabled(model.busy)
            }.padding(.vertical, 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(copy("连接 SSH 服务器，供本机测试和 MCP 执行远程命令。服务器地址与账号在“SSH 服务器”中管理。", "Connect to SSH servers for local tests and MCP commands. Manage addresses and accounts in SSH Servers."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let release = model.release {
                    Text(copy("可下载 \(release.version) · ", "Available \(release.version) · ") + release.size.formatted(.byteCount(style: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = model.availabilityError {
                    Text(copy("在线源暂不可用，可选择本地安装包。", "Online source unavailable. You can install a local package."))
                        .font(.caption).foregroundStyle(.secondary).help(error)
                }
                if let progress = model.progress {
                    HStack {
                        Text(progress.phase.title)
                        if let detail = progress.detail { Text(detail).monospacedDigit() }
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.error ?? model.status).font(.caption)
                        .foregroundStyle(model.error == nil ? Color.secondary : .red)
                        .lineLimit(2)
                }
            }.frame(height: 70, alignment: .topLeading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .bundle, .directory]) { result in
            switch result {
            case .success(let source): Task { await model.install(source: source) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .confirmationDialog(copy("卸载 SSH 插件？", "Uninstall the SSH plugin?"), isPresented: $confirmingRemoval) {
            Button(copy("卸载", "Uninstall"), role: .destructive) { Task { await model.uninstall() } }
        } message: { Text(copy("保留服务器账号和凭据。已有 MCP 进程需要重新连接后才会停用插件。", "Server accounts and credentials are kept. Reconnect existing MCP clients to deactivate the plugin.")) }
    }
}
