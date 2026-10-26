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
    var removing = false
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
        guard !busy else { return }; busy = true; removing = true; defer { busy = false; removing = false }
        do {
            try await manager.uninstall(); installed = nil; error = nil
            status = AppCopy.current.text("已卸载。连接和账号已保留，请重新连接 MCP 客户端。", "Uninstalled. Accounts were kept. Reconnect MCP clients.")
        } catch { self.error = error.localizedDescription }
    }
}
