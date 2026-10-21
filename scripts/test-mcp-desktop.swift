// Routine rendering is offscreen. The optional scoped mouse check requires verified screen/input shielding.
import AppKit
import Foundation
import SwiftUI
@testable import QueryCraftFeature

struct CheckFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message: message) }
}

@main struct MCPDesktopCheck {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args[1]), root = URL(fileURLWithPath: args[2])
        let broken = URL(fileURLWithPath: args[3]), previews = URL(fileURLWithPath: args[4])
        if ProcessInfo.processInfo.environment["QC_MCP_COMPONENT_CHECKS"] == "1" {
            try await MCPComponentCheck.run(source: source, root: root, serving: previews.appending(path: "catalog"),
                baseURL: URL(string: ProcessInfo.processInfo.environment["QC_MCP_COMPONENT_BASE_URL"]!)!)
            return
        }
        if ProcessInfo.processInfo.environment["QC_MCP_RENDER_ONLY"] == "1" {
            let model = MCPSettingsModel(directory: root, skillHomeDirectory: root.appending(path: "SkillHome"), clientRegistrar: MCPClientRegistration(home: root.appending(path: "ClientHome"), environment: [:]), skillInstaller: MCPSkillInstallation(source: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Components/Skill/querycraft")))
            model.didLoad = true; model.runtimeStatusLoaded = true; model.policy.enabled = true; model.installedVersion = "0.1.0"; model.availableVersion = "0.1.0"
            model.executable = source.appending(path: "Contents/MacOS/querycraft-mcp").path
            model.groups = ["生产环境", "测试环境", "开发环境"].enumerated().map { index, name in
                ConnectionGroup(id: UUID(), name: name, sortIndex: index, createdAt: Date())
            }
            model.profiles = DatabaseType.allCases.enumerated().map { index, type in
                ConnectionProfile(id: UUID(), name: type.rawValue + " 测试连接", groupID: model.groups[index % 3].id, databaseType: type,
                    host: "127.0.0.1", port: 3306, username: "test", defaultDatabase: nil, tlsMode: .disabled,
                    storesCredential: false, createdAt: Date())
            }
            model.policy.mode = .fullAccess
            model.policy.groupIDs = Set(model.groups.map(\.id))
            for (index, group) in model.groups.enumerated() {
                model.policy.groupModes[group.id.uuidString] = MCPExecutionMode.allCases[index]
            }
            model.selectedConnection = model.profiles.first?.id
            for profile in model.profiles {
                model.policy.connections[profile.id.uuidString] = .init(databases: ["demo"], databaseAccess: .selected)
                model.databaseChoices[profile.id] = ["demo", "archive", "analytics"]
            }
            if ProcessInfo.processInfo.environment["QC_MCP_PERMISSION_PERFORMANCE_ONLY"] == "1" {
                model.groups = []
                model.profiles = model.profiles.prefix(5).map { profile in
                    ConnectionProfile(id: profile.id, name: profile.name, groupID: nil, databaseType: profile.databaseType,
                        host: profile.host, port: profile.port, username: profile.username, defaultDatabase: nil,
                        tlsMode: .disabled, storesCredential: false, createdAt: profile.createdAt)
                }
                model.policy.groupIDs = []; model.policy.connectionIDs = Set(model.profiles.map(\.id))
                for profile in model.profiles { model.policy.connections[profile.id.uuidString] = .init(mode: .dataWrite) }
                model.selectSettingsPage("connections")
                let host = NSHostingView(rootView: MCPSettingsPane(model: model))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 790, height: 818),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
                func popups(_ view: NSView) -> [NSPopUpButton] {
                    (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
                }
                print("POPUPS", popups(host).count)
                let initialPolicy = model.policy
                if let native = popups(host).first(where: { $0.itemArray.first?.representedObject as? String == "custom" }),
                   let index = native.itemArray.firstIndex(where: { $0.representedObject as? String == "readOnly" }),
                   let action = native.action {
                    native.selectItem(at: index)
                    NSApp.sendAction(action, to: native.target, from: native)
                    try check(model.groupSelection(model.permissionGroups[0]) == .readOnly, "native group action did not update policy")
                    try check(model.profiles.allSatisfy { model.rule(for: $0.id).mode == .readOnly }, "group action skipped a connection")
                    print("PASS native permission action updates all members without input simulation")
                    host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
                }
                if let native = popups(host).first(where: { $0.itemArray.first?.representedObject as? String == "inherited" }),
                   let index = native.itemArray.firstIndex(where: { $0.representedObject as? String == "fullAccess" }),
                   let action = native.action {
                    native.selectItem(at: index)
                    NSApp.sendAction(action, to: native.target, from: native)
                    try check(model.profiles.filter { model.rule(for: $0.id).mode == .fullAccess }.count == 1,
                              "native row action did not update exactly one connection")
                    print("PASS native row action updates exactly one connection")
                }
                model.policy = initialPolicy
                host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
                model.isBusy = true
                host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
                let permissionButtons = popups(host).filter { ["custom", "inherited"].contains($0.itemArray.first?.representedObject as? String ?? "") }
                try check(!permissionButtons.isEmpty && permissionButtons.allSatisfy { !$0.isEnabled }, "busy settings left native permission controls enabled")
                if let button = permissionButtons.first, let action = button.action {
                    button.selectItem(at: button.numberOfItems - 1)
                    NSApp.sendAction(action, to: button.target, from: button)
                    try check(model.policy == initialPolicy, "disabled native permission control changed policy")
                }
                model.isBusy = false
                host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
                print("PASS native permission controls honor disabled settings")
                let group = model.permissionGroups[0], profile = model.profiles[0]
                var timings: [[String: Any]] = []
                for selection in [MCPPermissionSelection.readOnly, .dataWrite, .fullAccess, .denied, .dataWrite] {
                    for grouped in [true, false] {
                        let actualSelection = grouped ? selection : (selection == .readOnly ? .fullAccess : selection == .dataWrite ? .denied : .readOnly)
                        let start = ContinuousClock.now
                        if grouped { model.setGroupSelection(actualSelection, for: group) }
                        else { model.setConnectionSelection(actualSelection, for: profile) }
                        let setter = start.duration(to: .now)
                        host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
                        let elapsed = start.duration(to: .now)
                        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
                        timings.append(["group": grouped, "selection": actualSelection.rawValue, "setter_ms": ms(setter), "layout_ms": ms(elapsed)])
                    }
                }
                try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys]).write(to: previews.appending(path: "permission-performance.json"))
                print("PERMISSION_TIMINGS", String(decoding: try JSONSerialization.data(withJSONObject: timings), as: UTF8.self))
                return
            }
            if ProcessInfo.processInfo.environment["QC_MCP_SCOPE_PREVIEW_ONLY"] == "1" {
                try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
                model.selectSettingsPage("connections")
                try await render(model, dark: true, width: 790, height: 818, url: previews.appending(path: "connections.png"))
                try await render(model, dark: false, width: 490, height: 800, url: previews.appending(path: "narrow-connections.png"))
                let profile = model.profiles[0]
                for dark in [false, true] {
                    try await renderContent(MCPConnectionScopeEditor(model: model, profile: profile), dark: dark,
                        width: 640, height: 610, url: previews.appending(path: "scope-\(dark ? "dark" : "light").png"))
                }
                model.policy.connections[profile.id.uuidString] = .init(databases: [], databaseAccess: .selected)
                model.databaseChoices[profile.id] = []
                model.loadingDatabaseChoices.insert(profile.id)
                try await renderContent(MCPConnectionScopeEditor(model: model, profile: profile), dark: true,
                    width: 640, height: 610, url: previews.appending(path: "scope-loading.png"))
                model.loadingDatabaseChoices.remove(profile.id)
                model.databaseChoiceErrors[profile.id] = "连接暂时不可用，请重试。"
                try await renderContent(MCPConnectionScopeEditor(model: model, profile: profile), dark: true,
                    width: 640, height: 610, url: previews.appending(path: "scope-error.png"))
                model.databaseChoiceErrors[profile.id] = nil
                try await renderContent(MCPConnectionScopeEditor(model: model, profile: profile), dark: false,
                    width: 640, height: 610, url: previews.appending(path: "scope-empty.png"))
                let policy = model.policy
                let host = NSHostingView(rootView: MCPSettingsPane(model: model))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 790, height: 818),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
                try await Task.sleep(for: .milliseconds(300))
                model.navigate(to: .objects)
                try await Task.sleep(for: .milliseconds(600))
                try check(window.attachedSheet != nil, "object settings did not open a native sheet")
                model.scopeEditorConnection = nil
                try await Task.sleep(for: .milliseconds(600))
                try check(window.attachedSheet == nil && model.policy == policy, "closing scope sheet changed policy")
                window.orderOut(nil); window.contentView = nil; window.close()
                print("PASS scope sheet presents, cancels without changing policy, and renders stable light/dark/loading/error/empty states")
                return
            }
            if ProcessInfo.processInfo.environment["QC_MCP_NAVIGATION_PREVIEW_ONLY"] == "1" {
                try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
                model.selectSettingsPage("connections")
                try await render(model, dark: true, width: 790, height: 818,
                                 url: previews.appending(path: "single-tabbar-connections.png"))
                model.groups = []
                model.profiles = model.profiles.map { profile in
                    ConnectionProfile(id: profile.id, name: profile.name, groupID: nil, databaseType: profile.databaseType,
                        host: profile.host, port: profile.port, username: profile.username, defaultDatabase: profile.defaultDatabase,
                        tlsMode: profile.tlsMode, storesCredential: false, createdAt: profile.createdAt)
                }
                model.policy.groupIDs = []; model.policy.connectionIDs = Set(model.profiles.prefix(1).map(\.id))
                try await render(model, dark: true, width: 790, height: 950,
                                 url: previews.appending(path: "ungrouped-connection-rows.png"))
                try await render(model, dark: false, width: 490, height: 800,
                                 url: previews.appending(path: "narrow-connection-rows.png"))
                model.connectionFilterVisible = true; model.search = "mysql"
                try await render(model, dark: false, width: 790, height: 818,
                                 url: previews.appending(path: "connection-filter.png"))
                model.connectionFilterVisible = false; model.search = ""
                model.selectSettingsPage("execution")
                try await render(model, dark: true, width: 790, height: 818,
                                 url: previews.appending(path: "single-tabbar-limits.png"))
                try await render(model, dark: false, width: 490, height: 700,
                                 url: previews.appending(path: "single-tabbar-narrow.png"))
                print("PASS focused single-tabbar native previews rendered")
                return
            }
            try await measureSettingsLayout(model, previews: previews)
            if ProcessInfo.processInfo.environment["QC_MCP_INDEX_ISOLATION"] != nil {
                try await checkSettingsIndexAction(model)
            }
            if ProcessInfo.processInfo.environment["QC_MCP_MEASURE_ONLY"] == "1" { return }
            try await captureSettings(model, previews: previews)
            return
        }

        guard ProcessInfo.processInfo.environment["QC_MCP_LAUNCHD_CHECKS"] == "1" else {
            throw CheckFailure(message: "Persistent HTTP lifecycle checks require --launchd-checks; macOS may show background-activity notifications.")
        }

        if args.count > 6 {
            let loader = DatabaseDriverPackageInstaller(
                driversDirectory: URL(fileURLWithPath: args[6]),
                compatibilityValidator: .init(appVersion: "0.1.9"),
                maintainsInstalledDrivers: true)
            let loaded = await loader.loadInstalledDrivers()
            let types = await DatabaseDriverRegistry.shared.installedDatabaseTypes()
            try check(loaded.count == 6 && Set(types) == Set(DatabaseType.allCases), "desktop did not load all six packaged drivers")
            print("PASS signed desktop host loads all six drivers including shared MySQL/Doris transport")
        }
        let installer = MCPInstallation(root: root.appending(path: "MCP"), localPackage: source)
        try check(try await installer.installedVersion() == nil, "unexpected existing installation")
        try await installer.install()
        let version = try await installer.installedVersion()
        try check(version != nil, "installed runtime missing")
        let activationModel = MCPSettingsModel(directory: root, installation: installer,
            service: MCPServiceManager(directory: root, agentsDirectory: root.appending(path: "LaunchAgents")),
            skillHomeDirectory: root.appending(path: "SkillHome"),
            clientRegistrar: MCPClientRegistration(home: root.appending(path: "ClientHome"), environment: [:]), skillInstaller: MCPSkillInstallation(source: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Components/Skill/querycraft")))
        let entryStarted = Date()
        let activation = Task { await activationModel.activate() }
        while !activationModel.didLoad && activationModel.error == nil && Date().timeIntervalSince(entryStarted) < 20 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let settingsMilliseconds = Date().timeIntervalSince(entryStarted) * 1000
        try check(activationModel.didLoad && !activationModel.isBusy, "initial settings did not become independently editable")
        activationModel.policy.maximumRows = 777
        await activation.value
        let checkedMilliseconds = Date().timeIntervalSince(entryStarted) * 1000
        try check(activationModel.installedVersion == version && activationModel.runtimeStatusLoaded, "background runtime check failed")
        let returned = Date()
        await activationModel.activate()
        try check(activationModel.policy.maximumRows == 777, "returning to MCP reset unsaved settings")
        print(String(format: "PASS native settings activation: data ready %.1f ms, runtime checked %.1f ms, cached reentry %.3f ms", settingsMilliseconds, checkedMilliseconds, Date().timeIntervalSince(returned) * 1000))
        try await installer.install()
        try check(try await installer.installedVersion() == version, "update failed")
        let failing = MCPInstallation(root: root.appending(path: "MCP"), localPackage: broken)
        do { try await failing.install(); throw CheckFailure(message: "bad update unexpectedly installed") }
        catch is MCPFailure {}
        try check(try await installer.installedVersion() == version, "failed replacement did not restore previous runtime")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "MCP").path)
        try check(!leftovers.contains { $0.hasPrefix(".install-") || $0.hasPrefix(".previous-") }, "staging leaked")
        print("PASS signed installation, repeated update, post-replacement self-test failure rollback and staging cleanup")
        var policy = MCPPolicy(); policy.enabled = true
        policy.http.port = Int(args[5])!
        try MCPPolicyStore(directory: root).save(policy)
        let service = MCPServiceManager(directory: root, agentsDirectory: root.appending(path: "LaunchAgents"))
        do {
            try await service.start(executable: await installer.executableURL.path, settings: policy.http)
            try check(await service.isRunning(), "launchd service not running")
            try await service.start(executable: await installer.executableURL.path, settings: policy.http)
            try check(await service.isRunning(), "launchd restart failed")
            let editor = MCPSettingsModel(directory: root, installation: installer, service: service, skillHomeDirectory: root.appending(path: "SkillHome"), clientRegistrar: MCPClientRegistration(home: root.appending(path: "ClientHome"), environment: [:]), skillInstaller: MCPSkillInstallation(source: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Components/Skill/querycraft")))
            await editor.load()
            editor.policy.http.port = policy.http.port == 5229 ? 5230 : 5229
            await editor.install()
            try check(editor.error == nil && editor.httpRunning, "update lost HTTP service when settings had unsaved edits")
            try check(editor.policy.http.port != policy.http.port, "update overwrote unsaved HTTP editor values")
            print("PASS desktop update restarts saved HTTP configuration and preserves unsaved editor values")
            editor.policy.http.port = 0
            await editor.setHTTPRunning(false)
            try check(editor.error == nil && !editor.httpRunning, "invalid unsaved settings prevented stopping HTTP")
            try check(editor.policy.http.port == 0 && (try MCPPolicyStore(directory: root).load().http.port) == policy.http.port,
                      "stopping HTTP saved or discarded invalid editor values")
            try check(!(await service.isRunning()), "launchd service survived stop")
            editor.policy.http.port = policy.http.port
            await editor.setHTTPRunning(true)
            try check(editor.error == nil && editor.httpRunning, "settings action failed to restart HTTP after invalid edit")
            await editor.setHTTPRunning(false)
            try check(editor.error == nil && !editor.httpRunning, "settings action failed to stop HTTP")
            print("PASS settings HTTP start/stop/recovery; invalid unsaved settings cannot prevent stopping")
        } catch { try? await service.stop(); throw error }
        print("PASS real launchd bootstrap, authenticated HTTP readiness, restart and stop in isolated storage")
        if let delayed = ProcessInfo.processInfo.environment["QC_MCP_DELAYED_EXECUTABLE"] {
            let started = Date()
            try await service.start(executable: delayed, settings: policy.http)
            try check(Date().timeIntervalSince(started) >= 5, "delayed startup fixture did not delay")
            try check(await service.isRunning(), "delayed HTTP runtime did not start")
            try await service.stop()
            print("PASS HTTP readiness tolerates a deliberately delayed five-second cold startup")
        }
        try await installer.uninstall()
        try check(try await installer.installedVersion() == nil, "uninstall failed")
        try check(try MCPPolicyStore(directory: root).load().enabled, "uninstall removed policy")
        print("PASS uninstall preserves configuration")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for client in MCPClientConfiguration.clients {
            for http in [false, true] where !http || MCPClientConfiguration.supportsHTTP(client) {
                let text = MCPClientConfiguration.make(client: client, executable: source.appending(path: "Contents/MacOS/querycraft-mcp").path,
                    dataDirectory: root.path, http: http ? policy.http : nil)
                try text.write(to: previews.appending(path: client + (http ? "-http.txt" : "-stdio.txt")), atomically: true, encoding: .utf8)
            }
        }
        let model = MCPSettingsModel(directory: root, installation: installer, service: service, skillHomeDirectory: root.appending(path: "SkillHome"), clientRegistrar: MCPClientRegistration(home: root.appending(path: "ClientHome"), environment: [:]), skillInstaller: MCPSkillInstallation(source: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Components/Skill/querycraft")))
        model.didLoad = true; model.policy.enabled = true
        model.policy.maximumRows = 321
        model.save()
        try check(try MCPPolicyStore(directory: root).load().maximumRows == 321, "settings save did not persist")
        model.policy.maximumRows = 654
        await model.recheck()
        try check(model.policy.maximumRows == 654, "recheck lost unsaved changes")
        let history = MCPHistoryStore(directory: root)
        try await history.append(.init(id: UUID().uuidString, startedAt: Date(), tool: "list_connections",
            connectionID: nil, durationMilliseconds: 2, succeeded: true, errorCode: nil, resultBytes: 10))
        await model.loadHistory()
        try check(model.historyRows.count == 1, "settings history did not load")
        print("PASS settings save, recheck preserves unsaved settings, and shared call history loading")
        model.installedVersion = version; model.availableVersion = version
        model.executable = source.appending(path: "Contents/MacOS/querycraft-mcp").path
        model.policy.http = policy.http; model.save()
        try await service.start(executable: model.executable, settings: model.policy.http)
        for client in ["Codex", "Claude Code", "Cursor", "VS Code", "OpenCode"] {
            model.client = client
            for transport in ["stdio", "http"] {
                model.transport = transport
                await model.inspectClientRegistration()
                try check(model.clientRegistrationError == nil, "client registration inspection failed: \(client)")
                await model.changeClientRegistration(adding: true)
                try check(model.clientRegistrationError == nil && model.clientRegistration?.state == .registered, "one-click add failed: \(client) \(transport)")
                await model.changeClientRegistration(adding: true)
                try check(model.clientRegistrationError == nil, "repeated one-click add failed: \(client)")
                if client == "Claude Code", FileManager.default.isExecutableFile(atPath: "/usr/local/bin/claude") {
                    var env = ProcessInfo.processInfo.environment
                    env["CLAUDE_CONFIG_DIR"] = root.appending(path: "ClientHome").path
                    let output = try await MCPProcess.run(URL(fileURLWithPath: "/usr/local/bin/claude"), arguments: ["mcp", "list"], timeout: 60, environment: env, workingDirectory: root)
                    try check(output.contains("querycraft") && output.contains("Connected"), "Claude did not connect using one-click user configuration: \(transport)")
                }
            }
            await model.changeClientRegistration(adding: false)
            try check(model.clientRegistrationError == nil && model.clientRegistration?.state == .absent, "one-click remove failed: \(client)")
        }
        model.client = "Claude Code"; model.transport = "stdio"
        try await service.stop()
        print("PASS settings one-click add, repeat, stdio/HTTP update and remove for five clients; Claude actual user-config connection")
        model.profiles = DatabaseType.allCases.map { type in
            ConnectionProfile(id: UUID(), name: type.rawValue + " 测试连接", groupID: nil, databaseType: type,
                host: "127.0.0.1", port: 3306, username: "test", defaultDatabase: nil, tlsMode: .disabled,
                storesCredential: false, createdAt: Date())
        }
        model.policy.connectionIDs = Set(model.profiles.prefix(3).map(\.id))
        model.selectedConnection = model.profiles.first?.id
        for profile in model.profiles { model.databaseChoices[profile.id] = ["demo", "archive", "analytics"] }
        let repository = SQLiteConnectionProfileRepository(databaseURL: root.appending(path: "QueryCraft.sqlite"))
        for profile in model.profiles {
            try await repository.insert(profile)
            model.policy.connections[profile.id.uuidString] = .init(databases: ["demo"], mode: .dataWrite,
                databaseModes: ["demo": .readOnly], databaseAccess: .selected)
        }
        model.policy.mode = .fullAccess
        model.policy.disabledTools = ["remove_connection"]
        model.save()
        let reopened = MCPSettingsModel(directory: root, installation: installer, service: service, skillHomeDirectory: root.appending(path: "SkillHome"), clientRegistrar: MCPClientRegistration(home: root.appending(path: "ClientHome"), environment: [:]), skillInstaller: MCPSkillInstallation(source: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Components/Skill/querycraft")))
        await reopened.load()
        try check(reopened.error == nil && reopened.profiles.count == 6 && reopened.policy == model.policy,
                  "four-step permission settings did not survive reopening")
        for profile in reopened.profiles {
            try check(reopened.policy.effectiveMode(profile, database: "demo") == .readOnly, "database permission override was lost")
        }
        print("PASS six-driver connections and all four permission steps persist after settings reopen")
        for target in MCPSkillTarget.allCases {
            reopened.skillTarget = target
            await reopened.inspectSkill()
            try check(reopened.skillStatus == .notInstalled, "unexpected skill in isolated home")
            await reopened.changeSkillInstallation(install: true)
            try check(reopened.skillError == nil && reopened.skillStatus == .current, "settings skill install failed")
            let entry = reopened.skillDirectory.appending(path: "SKILL.md")
            let original = try Data(contentsOf: entry)
            try Data("local modification".utf8).write(to: entry)
            await reopened.changeSkillInstallation(install: false)
            try check(reopened.skillError != nil && FileManager.default.fileExists(atPath: entry.path), "modified skill was removed")
            try original.write(to: entry)
            await reopened.changeSkillInstallation(install: false)
            try check(reopened.skillError == nil && reopened.skillStatus == .notInstalled, "skill uninstall did not recover")
        }
        await reopened.install()
        try check(reopened.error == nil && reopened.installedVersion != nil, "settings runtime installation failed")
        await reopened.uninstall()
        try check(reopened.error == nil && reopened.installedVersion == nil, "settings runtime uninstall failed")
        print("PASS settings runtime install/uninstall and all three Skill destinations, local-edit protection and recovery")
        // Later lifecycle checks expect an empty connection catalog.
        for profile in model.profiles { try await repository.delete(id: profile.id) }
        try await captureSettings(model, previews: previews)
        // Leave only this isolated service alive for the Python parent to verify
        // after the desktop harness process has completely exited.
        try await installer.install()
        try MCPPolicyStore(directory: root).save(policy)
        try await service.start(executable: await installer.executableURL.path, settings: policy.http)
        print("PASS isolated desktop host prepared HTTP service for post-exit lifecycle checks")
    }
    @MainActor static func measureSettingsLayout(_ model: MCPSettingsModel, previews: URL) async throws {
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        model.section = "permissions"; model.authorizationStep = "connections"
        let originalPolicy = model.policy
        model.historyLoading = true // Directory navigation must not load fixture history from storage.
        let host = NSHostingView(rootView: MCPSettingsPane(model: model))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 790, height: 818),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        var timings: [[String: Any]] = []
        print("BEGIN grouped permission layout measurement pid=\(ProcessInfo.processInfo.processIdentifier)")
        for step in ["tools", "execution", "tuning", "ceiling", "tools"] {
            let start = Date()
            model.authorizationStep = step
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            timings.append(["step": step, "milliseconds": Date().timeIntervalSince(start) * 1000])
        }
        for destination in MCPSettingsDestination.allCases {
            model.navigate(to: destination)
            model.scopeEditorConnection = nil // Scope sheets are rendered and checked separately.
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        try check(model.policy == originalPolicy, "settings directory navigation changed policy")
        model.section = "permissions"
        model.authorizationStep = "tools"
        let probe = MCPToolCatalog.definitions[0].name
        model.policy.disabledTools.insert(probe)
        model.policy.mode = .dataWrite
        model.section = "access"
        host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield()
        model.section = "permissions"
        host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield()
        try check(model.policy.disabledTools.contains(probe) && model.policy.mode == .dataWrite,
                  "settings navigation overwrote unsaved permission edits")
        model.policy = originalPolicy
        print("PASS complete settings navigation preserves policy and unsaved permission edits")
        model.historyLoading = true // Keep the fixture independent of the pane's history task.
        model.historyLoaded = true
        model.historyRows = (0..<500).map { index in
            MCPCallRecord(id: "layout-\(index)", startedAt: Date().addingTimeInterval(Double(-index)),
                          tool: "querycraft_execute_query", connectionID: model.profiles.first?.id.uuidString,
                          durationMilliseconds: index, succeeded: index % 5 != 0,
                          errorCode: index % 5 == 0 ? "ACCESS_DENIED" : nil, resultBytes: index)
        }
        model.section = "activity"
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        guard let tableScroll = scrollViews(host).max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }) else {
            throw CheckFailure(message: "history table has no scroll view")
        }
        var ancestor = tableScroll.superview
        while let view = ancestor {
            try check(!(view is NSScrollView), "history table is still nested in another scroll view")
            ancestor = view.superview
        }
        let activityScrollViews = [tableScroll]
        let scrolls = activityScrollViews.map { scroll -> [String: Any] in
            let before = scroll.contentView.bounds.origin
            let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            let after = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: before)
            return ["viewport_height": scroll.contentSize.height, "document_height": scroll.documentView?.bounds.height ?? 0,
                    "vertical_scroller": scroll.hasVerticalScroller, "can_scroll": maximum > 0 && after.y != before.y]
        }
        try check(scrolls.allSatisfy { $0["can_scroll"] as? Bool == true && $0["vertical_scroller"] as? Bool == true },
                  "history cannot scroll through all 500 records with a native scroller")
        let scroll = activityScrollViews[0]
        let loadedHeight = scroll.frame.height
        model.historyLoading = false; model.historyError = "模拟加载失败，保留已有记录。"
        host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
        try check(abs(scroll.frame.height - loadedHeight) < 1 && model.historyRows.count == 500,
                  "history loading/error feedback changed the table viewport or discarded rows")
        var resizeMetrics: [[String: Any]] = []
        // The harness controls the proposed content size explicitly; do not let
        // NSHostingView carry a previous permission page's inferred window min.
        host.sizingOptions = []
        window.minSize = .zero
        for height: CGFloat in [500, 1000] {
            window.setContentSize(NSSize(width: 790, height: height))
            try await Task.sleep(for: .milliseconds(50))
            host.setFrameSize(NSSize(width: 790, height: height))
            host.needsLayout = true; host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            resizeMetrics.append(["window_height": height, "actual_host_height": host.bounds.height, "table_viewport_height": scroll.contentSize.height])
            try check(scroll.contentSize.height >= 100 && scroll.convert(scroll.bounds, to: host).minY >= 44,
                      "history table is clipped or overlaps the settings footer")
        }
        model.historyLoading = true; model.historyError = nil
        let record: [String: Any] = ["permission_switches": timings, "activity_scroll_views": scrolls, "activity_resize": resizeMetrics]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: previews.appending(path: "layout-metrics.json"))
        try check((resizeMetrics[1]["table_viewport_height"] as? CGFloat ?? 0) > (resizeMetrics[0]["table_viewport_height"] as? CGFloat ?? 0) + 400,
                  "history table does not grow with the window: \(resizeMetrics)")
        print("PASS isolated native layout measurement; navigation preserved unsaved policy")
    }

    @MainActor static func checkSettingsIndexAction(_ model: MCPSettingsModel) async throws {
        guard let isolation = ProcessInfo.processInfo.environment["QC_MCP_INDEX_ISOLATION"] else {
            throw CheckFailure(message: "settings index interaction requires screen/input isolation")
        }
        func requireIsolation() throws {
            try check(FileManager.default.fileExists(atPath: isolation + "/shield.ready"), "screen/input isolation ended")
        }
        try requireIsolation()
        let originalPolicy = model.policy
        model.section = "activity"; model.settingsScrollTarget = nil
        let host = NSHostingView(rootView: MCPSettingsPane(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 818),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "QueryCraft 设置跳转验证 · Esc 退出"
        window.isReleasedWhenClosed = false; window.contentView = host
        NSApplication.shared.setActivationPolicy(.accessory)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
        func click(_ target: NSWindow, x: CGFloat, fromTop: CGFloat) throws {
            try requireIsolation()
            guard let content = target.contentView else { throw CheckFailure(message: "missing interaction content") }
            let location = NSPoint(x: x, y: content.bounds.height - fromTop)
            // Deliver only to this synthetic window, without posting global HID events or moving the cursor.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw CheckFailure(message: "could not create scoped mouse event")
                }
                target.sendEvent(event)
            }
        }
        try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
        try click(window, x: 65, fromTop: host.bounds.height - 22)
        try await Task.sleep(for: .milliseconds(500))
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            throw CheckFailure(message: "one click did not open the settings index")
        }
        // First directory row, deliberately in its blank middle rather than on its text or chevron.
        try click(sheet, x: content.bounds.width / 2, fromTop: 164)
        try await Task.sleep(for: .milliseconds(700))
        try requireIsolation()
        try check(window.attachedSheet == nil, "single row click did not dismiss the index")
        try check(model.section == "access" && model.settingsScrollTarget == "access-runtime",
                  "single row click did not navigate after dismissal")
        try check(model.policy == originalPolicy, "index action changed the policy")
        print("PASS one scoped mouse click on a directory row closes the sheet and navigates without changing policy, under verified isolation")
    }

    @MainActor static func captureSettings(_ model: MCPSettingsModel, previews: URL) async throws {
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let scenarios = [("access", "connections", "stdio"), ("access", "connections", "http"),
            ("permissions", "connections", "stdio"), ("permissions", "objects", "stdio"),
            ("permissions", "ceiling", "stdio"), ("permissions", "tools", "stdio"),
            ("permissions", "execution", "stdio"), ("permissions", "tuning", "stdio"),
            ("activity", "connections", "stdio")]
        for (section, step, transport) in scenarios {
            model.section = section; model.authorizationStep = step == "objects" ? "connections" : step; model.transport = transport
            model.showsHTTPSettings = false; model.connectionFilterVisible = false
            model.settingsScrollTarget = nil

            model.scopeEditorConnection = nil
            for dark in [false, true] {
                try await render(model, dark: dark, width: 540, height: 660,
                    url: previews.appending(path: "\(section)-\(step)-\(transport)-\(dark ? "dark" : "light").png"))
            }
        }
        model.section = "permissions"; model.authorizationStep = "connections"; model.scopeEditorConnection = nil; model.settingsScrollTarget = nil
        try await render(model, dark: true, width: 790, height: 818,
                         url: previews.appending(path: "flat-connections.png"))
        model.showPermissionPage("execution")
        try await render(model, dark: true, width: 790, height: 818,
                         url: previews.appending(path: "flat-execution.png"))
        try await render(model, dark: false, width: 490, height: 700,
                         url: previews.appending(path: "narrow-flat-tabs.png"))
        model.settingsScrollTarget = nil
        model.section = "permissions"; model.authorizationStep = "connections"

        model.scopeEditorConnection = nil
        try await render(model, dark: false, width: 790, height: 950,
                         url: previews.appending(path: "permissions-aligned.png"))
        try await render(model, dark: false, width: 490, height: 700,
                         url: previews.appending(path: "narrow-objects.png"))
        model.section = "permissions"
        for step in ["tools", "execution", "tuning", "ceiling"] {
            model.authorizationStep = step
            try await render(model, dark: false, width: 490, height: 500, url: previews.appending(path: "narrow-\(step).png"), scrollFraction: 1)
        }
        try await renderContent(MCPSettingsIndexView(select: { _ in }), dark: false, width: 640, height: 620,
                                url: previews.appending(path: "all-settings.png"))
        let installedVersion = model.installedVersion, availableVersion = model.availableVersion
        model.section = "access"
        model.installedVersion = "0.1.0"; model.availableVersion = "0.1.1"
        try await render(model, dark: true, width: 790, height: 818, url: previews.appending(path: "runtime-update-available.png"))
        try await render(model, dark: false, width: 490, height: 500, url: previews.appending(path: "narrow-runtime-update.png"))
        model.installedVersion = installedVersion; model.availableVersion = availableVersion
        try await renderContent(MCPSettingsReviewView(policy: model.policy, profiles: model.profiles, groups: model.groups, save: {}),
                                dark: false, width: 660, height: 660, url: previews.appending(path: "save-review.png"))
        model.section = "activity"
        try await render(model, dark: true, width: 490, height: 500, url: previews.appending(path: "narrow-activity.png"))
        try await render(model, dark: false, width: 790, height: 818, url: previews.appending(path: "activity-bottom.png"), scrollFraction: 1)
        model.section = "permissions"; model.authorizationStep = "connections"
        model.isBusy = true
        try await render(model, dark: false, width: 490, height: 450, url: previews.appending(path: "narrow-loading.png"))
        model.isBusy = false; model.error = "模拟失败：连接暂时不可用，请重试。"
        try await render(model, dark: false, width: 490, height: 450, url: previews.appending(path: "narrow-error.png"))
        print("PASS native settings rendered offscreen in light/dark, narrow loading/error states; no input simulation")
        model.isBusy = false; model.error = nil; model.status = ""
        model.section = "access"; model.transport = "stdio"
        await model.inspectClientRegistration()
        try await render(model, dark: true, width: 490, height: 500, url: previews.appending(path: "narrow-access.png"))
        try await render(model, dark: true, width: 790, height: 818, url: previews.appending(path: "reference-mcp.png"))
        let defaultsDomain = "QueryCraft.MCP.LayoutReference." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: defaultsDomain) else { throw CheckFailure(message: "no isolated defaults") }
        defer { defaults.removePersistentDomain(forName: defaultsDomain) }
        let preferences = ApplicationPreferences(userDefaults: defaults)
        try await renderContent(AppearanceSettingsPane(preferences: preferences), dark: true, width: 790, height: 818,
                                url: previews.appending(path: "reference-appearance.png"))
        model.client = "Codex"
        await model.inspectClientRegistration()
        try await render(model, dark: true, width: 790, height: 818, url: previews.appending(path: "reference-codex.png"))
        model.isBusy = true
        for (phase, name) in [(MCPComponentInstallationProgress.Phase.checking, "checking"), (.downloading, "downloading"), (.verifying, "verifying"), (.selfTesting, "self-testing")] {
            model.installationProgress = .init(phase: phase, receivedBytes: 4_194_304, totalBytes: 10_485_760, bytesPerSecond: 32_768)
            try await render(model, dark: true, width: 790, height: 818, url: previews.appending(path: "install-\(name).png"))
            try await render(model, dark: false, width: 490, height: 500, url: previews.appending(path: "narrow-install-\(name).png"))
        }
        model.isBusy = false; model.installationProgress = nil
        try await render(model, dark: true, width: 790, height: 818, url: previews.appending(path: "skill-section.png"), scrollFraction: 0.55)
        model.client = "Claude Code"
        await model.inspectClientRegistration()
        try await render(model, dark: true, width: 1050, height: 800, url: previews.appending(path: "wide-access.png"))
        try await render(model, dark: true, width: 1050, height: 800, url: previews.appending(path: "wide-access-bottom.png"), scrollFraction: 1)
        model.section = "permissions"; model.authorizationStep = "tools"
        try await render(model, dark: true, width: 1050, height: 800, url: previews.appending(path: "wide-tools-bottom.png"), scrollFraction: 1)
    }
    @MainActor static func render(_ model: MCPSettingsModel, dark: Bool, width: CGFloat, height: CGFloat, url: URL, scrollFraction: Double = 0) async throws {
        try await renderContent(MCPSettingsPane(model: model), dark: dark, width: width, height: height, url: url, scrollFraction: scrollFraction)
    }
    @MainActor static func renderContent<Content: View>(_ content: Content, dark: Bool, width: CGFloat, height: CGFloat, url: URL, scrollFraction: Double = 0) async throws {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, ApplicationLanguage.activeInterfaceLanguage.locale))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        if scrollFraction > 0 {
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
            }
            if let scroll = scrollViews(in: host).max(by: {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            }), let document = scroll.documentView {
                let offset = max(0, document.frame.height - scroll.contentSize.height) * scrollFraction
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
            }
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(message: "no bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(message: "no PNG") }
        try png.write(to: url)
        window.orderOut(nil); window.contentView = nil; window.close()
    }
}
