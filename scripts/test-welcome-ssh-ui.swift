import AppKit
import SwiftUI
@testable import QueryCraftFeature

struct WelcomeUIFailure: Error { let message: String }
@main struct WelcomeSSHUIValidation {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        let group = ConnectionGroup(id: UUID(), name: "开发环境 · Development", sortIndex: 0, createdAt: .now)
        let db = DatabaseType.allCases.enumerated().map { index, type in
            ConnectionProfile(id: UUID(), name: "\(index + 1) · \(type.rawValue)", groupID: nil, databaseType: type,
                host: "192.0.2.10", port: 1234, username: "admin", defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: .now)
        }
        let service = SSHConnectionService(directory: root, credentials: InMemoryCredentialStore())
        for (name, host) in [("Linux · 应用服务器", "192.0.2.33"), ("Jump · 跳板机", "192.0.2.34")] {
            let ssh = SSHConnection(id: UUID(), name: name, host: host, port: 22, username: "admin",
                hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: "/fixture/key", storesCredential: false)
            try await service.save(ssh, original: nil, secret: nil, access: .denied)
        }
        let accounts = SSHSettingsModel(service: service)
        let repository = InMemoryConnectionProfileRepository(profiles: db, groups: [group])
        let welcome = WelcomeModel(repository: repository, credentialStore: InMemoryCredentialStore(), connectionTester: InMemoryConnectionTester(), ssh: accounts)
        await welcome.loadProfiles()
        guard welcome.connectionCount == 8 else { throw WelcomeUIFailure(message: "unified count") }
        let scripts = ShellScriptSettingsModel(service: ShellScriptLibraryService(directory: root))
        await scripts.load()
        let permissions = MCPSettingsModel(directory: root)
        permissions.didLoad = true; permissions.runtimeStatusLoaded = true; permissions.policy.enabled = true
        permissions.profiles = db; permissions.sshProfiles = accounts.profiles
        permissions.authorizationStep = "connections"; permissions.section = "permissions"
        let plugin = SSHPluginSettingsModel(); plugin.installed = "0.9.0"; plugin.checked = true
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await render(ContentView(model: welcome, loadsApplicationState: false), dark: dark, width: 900, height: 680,
                to: output.appending(path: "home-\(suffix).png"))
            try await render(ContentView(model: welcome, loadsApplicationState: false), dark: dark, width: 740, height: 460,
                to: output.appending(path: "home-narrow-\(suffix).png"))
            let selection = NewConnectionFlowModel(); await selection.loadCatalog(); selection.selectedConnection = .ssh
            try await render(DatabaseDriverSelectionView(model: selection, cancel: {}, continueSelection: {}, uninstallSelection: {}), dark: dark, width: 620, height: 500,
                to: output.appending(path: "connection-types-\(suffix).png"))
            selection.searchText = "SSH"
            try await render(DatabaseDriverSelectionView(model: selection, cancel: {}, continueSelection: {}, uninstallSelection: {}), dark: dark, width: 620, height: 500,
                to: output.appending(path: "ssh-choice-\(suffix).png"))
            try await render(SSHSettingsPane(model: accounts, scripts: scripts), dark: dark, width: 500, height: 620,
                to: output.appending(path: "script-settings-\(suffix).png"))
            // A searched mixed list makes both row types visible without scrolling the user's desktop.
            permissions.search = "192.0.2."
            permissions.profiles = Array(db.prefix(2))
            try await render(MCPPermissionsSettingsPane(model: permissions), dark: dark, width: 860, height: 850,
                to: output.appending(path: "mcp-connections-\(suffix).png"))
            permissions.sshProfiles = []
            try await render(MCPPermissionsSettingsPane(model: permissions), dark: dark, width: 860, height: 850,
                to: output.appending(path: "mcp-no-ssh-\(suffix).png"))
            permissions.sshProfiles = accounts.profiles
            permissions.search = "SSH"
            try await render(MCPPermissionsSettingsPane(model: permissions), dark: dark, width: 580, height: 700,
                to: output.appending(path: "mcp-narrow-\(suffix).png"))
            try await render(Form {
                Section(AppCopy.current.text("连接插件", "Connection plugins")) {
                    ForEach(DatabaseDriverCatalog.entries) { entry in
                        PluginSettingsRow(item: DatabaseDriverCatalogItem(entry: entry, installationState: .installed,
                            installedVersion: "1.0.0"), install: {}, update: {}, uninstall: {})
                    }
                    PluginSettingsRow(item: ConnectionPluginPresentation(plugin), install: {}, update: {}, uninstall: {})
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden), dark: dark, width: 700, height: 680,
                to: output.appending(path: "plugins-\(suffix).png"))
        }
        // Refresh failures keep the existing SSH rows instead of silently
        // switching the unified catalog to an empty state.
        try Data("invalid-fixture".utf8).write(to: root.appending(path: "ssh-connections.json"))
        await accounts.load()
        guard accounts.error != nil && accounts.profiles.count == 2 else { throw WelcomeUIFailure(message: "failed refresh lost SSH accounts") }
        try await render(ContentView(model: welcome, loadsApplicationState: false), dark: true, width: 900, height: 680,
            to: output.appending(path: "failure-retains-accounts.png"))
        print("PASS unified native welcome: six database types and SSH, shared count, native outline rows, type picker/search, script-only settings, light/dark/narrow and failure retaining accounts; no user data or input simulation")
    }
    @MainActor static func render<V: View>(_ view: V, dark: Bool, width: CGFloat, height: CGFloat, to url: URL) async throws {
        let controller = NSHostingController(rootView: view.frame(width: width, height: height).background(dark ? Color.black : Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller; window.setContentSize(NSSize(width: width, height: height)); window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(600)); window.setContentSize(NSSize(width: width, height: height))
        let host = controller.view; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw WelcomeUIFailure(message: "no bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw WelcomeUIFailure(message: "no PNG") }
        try png.write(to: url)
    }
}
