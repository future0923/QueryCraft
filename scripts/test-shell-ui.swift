import AppKit
import SwiftUI
@testable import QueryCraftFeature

struct ShellUIFailure: Error { let message: String }

@main struct ShellUIValidation {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        let service = ShellScriptLibraryService(directory: root)
        let source = "#!/bin/sh\n# 查看磁盘与运行时间\nprintf '%s\\n' 'Health check'\ndf -h\nuptime\n"
        let record = try await service.save(original: nil, name: "磁盘与健康检查 · Disk health", description: "只查询服务器状态 · Read server status", script: source)
        _ = try await service.save(original: nil, name: "部署前检查 · Preflight", description: "检查工作目录与空间 · Inspect directory and free space", script: "pwd\ndf -h\n")
        let model = ShellScriptSettingsModel(service: service); await model.load()
        let profile = SSHConnection(id: UUID(), name: "Linux server", host: "192.0.2.33", port: 22, username: "admin",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: "/fixture/id_ed25519", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(profile)
        let accounts = SSHSettingsModel(service: SSHConnectionService(directory: root)); await accounts.load()
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await render(SSHSettingsPane(model: accounts, scripts: model), dark: dark, width: 500, height: 720,
                             to: output.appending(path: "ssh-integrated-\(suffix).png"))
            try await render(Form { ShellScriptSettingsSection(model: model) }.formStyle(.grouped).scrollContentBackground(.hidden), dark: dark, width: 480, height: 460,
                             to: output.appending(path: "library-\(suffix).png"))
            try await render(ShellScriptEditor(draft: ShellScriptDraft(), service: service), dark: dark, width: 660, height: 520,
                             to: output.appending(path: "new-editor-\(suffix).png"))
            let draft = ShellScriptDraft(original: record)
            try await render(ShellScriptEditor(draft: draft, service: service), dark: dark, width: 660, height: 520,
                             to: output.appending(path: "editor-\(suffix).png"))
            draft.script += "# local draft kept\n"; draft.error = ShellScriptSettingsModel.message(MCPFailure("changed", code: .sessionBusy))
            try await render(ShellScriptEditor(draft: draft, service: service), dark: dark, width: 660, height: 520,
                             to: output.appending(path: "editor-conflict-\(suffix).png"))
        }
        let loading = ShellScriptSettingsModel(service: ShellPreviewService(records: [], slow: true))
        try await render(Form { ShellScriptSettingsSection(model: loading) }.formStyle(.grouped), dark: false, width: 480, height: 460,
                         to: output.appending(path: "initial-loading.png"))
        let failed = ShellScriptSettingsModel(service: ShellPreviewService(records: [], fails: true))
        failed.records = model.records; failed.loaded = true
        try await render(Form { ShellScriptSettingsSection(model: failed) }.formStyle(.grouped), dark: true, width: 480, height: 460,
                         to: output.appending(path: "failure-retains-content.png"))
        let empty = ShellScriptSettingsModel(service: ShellPreviewService(records: []))
        try await render(Form { ShellScriptSettingsSection(model: empty) }.formStyle(.grouped), dark: false, width: 480, height: 460,
                         to: output.appending(path: "empty.png"))
        print("PASS offscreen native Shell settings integrated with SSH, source editor, light/dark, loading/empty/retained-error/conflict")
    }
    @MainActor static func render<V: View>(_ view: V, dark: Bool, width: CGFloat, height: CGFloat, to url: URL) async throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: width, height: height); window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ShellUIFailure(message: "no bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ShellUIFailure(message: "no PNG") }
        try png.write(to: url)
    }
}

private actor ShellPreviewService: ShellScriptLibraryServing {
    let records: [ShellScript]
    let slow: Bool
    let fails: Bool
    init(records: [ShellScript], slow: Bool = false, fails: Bool = false) { self.records = records; self.slow = slow; self.fails = fails }
    func list(force: Bool) async throws -> [ShellScript] {
        if slow { try await Task.sleep(for: .seconds(60)) }
        if fails { throw MCPFailure("unreadable", code: .policyUnavailable) }
        return records
    }
    func save(original: ShellScript?, name: String, description: String, script: String) throws -> ShellScript { throw MCPFailure("unused") }
    func remove(_ script: ShellScript) throws { throw MCPFailure("unused") }
}
