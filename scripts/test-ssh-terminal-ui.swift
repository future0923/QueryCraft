import AppKit
import MachO
import ScreenCaptureKit
import SwiftUI
@testable import QueryCraftFeature

struct TerminalUIFailure: Error { let message: String }
@main struct TerminalUIValidation {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TerminalUIFailure(message: message) }
    }
    @MainActor static func wait(_ condition: @MainActor () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<800 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw TerminalUIFailure(message: "Condition timed out at line \(line)")
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        if ProcessInfo.processInfo.environment["QC_TERMINAL_LIVE_ONLY"] == "1", args.count > 9 {
            try await live(host: args[8], directory: URL(fileURLWithPath: args[9])); return
        }
        if ProcessInfo.processInfo.environment["QC_INSTALL_DEV_SSH_ONLY"] == "1" {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/QueryCraftDev")
            let installed = try SSHPluginInstallation.install(source: URL(fileURLWithPath: args[3]), directory: directory)
            print("Installed signed SSH plugin:", installed.path)
            return
        }
        let root = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let current = root.appending(path: "Plugins/SSH/Current", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[3]), to: current.appending(path: "QueryCraftSSH.bundle"))
        let profile = SSHConnection(id: UUID(), name: "本机测试服务器 · Local SSH", host: "127.0.0.1", port: Int(args[4])!, username: args[5], hostFingerprint: args[6], privateKeyPath: args[7], storesCredential: false)
        try SSHConnectionStore(directory: root).insert(profile)
        let scriptMarker = root.appending(path: "script-executed.txt")
        let savedScript = try ShellScriptStore(directory: root).create(name: "检查服务器 · Inspect server", description: "本机测试示例 · Local test example", script: "printf '%s' \"a'b 中文\" > " + SSHTaskCommand.shellQuote(scriptMarker.path) + "\nprintf 'SAVED_SCRIPT_OK\\n'; pwd\n")
        let longMarker = root.appending(path: "large-script-executed.txt")
        let longScript = try ShellScriptStore(directory: root).create(name: "长脚本示例 · Long script", description: "", script: "QC_LARGE_VALUE='" + String(repeating: "x", count: 12000) + "'\nprintf '%s' LARGE_UI_OK > " + SSHTaskCommand.shellQuote(longMarker.path) + "\n")
        let installationRoot = root.appending(path: "installation-contract")
        let source = current.appending(path: "QueryCraftSSH.bundle")
        let installed = try SSHPluginInstallation.install(source: source, directory: installationRoot)
        let selected = SSHPlugin.bundleURL(in: installationRoot).resolvingSymlinksInPath()
        try require(selected == installed.resolvingSymlinksInPath(), "renderer package was not activated")
        if let fixtures = ProcessInfo.processInfo.environment["QUERYCRAFT_RENDERER_FIXTURES"] {
            for name in ["missing", "abi", "version", "corrupt"] {
                do {
                    _ = try SSHPluginInstallation.install(source: URL(fileURLWithPath: fixtures).appending(path: "\(name)/QueryCraftSSH.bundle"), directory: installationRoot)
                    throw TerminalUIFailure(message: "invalid renderer installed: \(name)")
                } catch is TerminalUIFailure { throw TerminalUIFailure(message: "invalid renderer installed: \(name)") }
                catch { try require(SSHPlugin.bundleURL(in: installationRoot).resolvingSymlinksInPath() == selected, "invalid renderer changed Current") }
            }
        }
        if let previous = ProcessInfo.processInfo.environment["QUERYCRAFT_PREVIOUS_SSH_BUNDLE"], !previous.isEmpty {
            _ = try SSHPlugin(bundleURL: URL(fileURLWithPath: previous))
            do { _ = try SSHTerminalSurface(bundleURL: URL(fileURLWithPath: previous)); throw TerminalUIFailure(message: "legacy renderer unexpectedly accepted") }
            catch let failure as MCPFailure { try require(failure.code == .unsupported, "legacy renderer fallback is incorrect") }
        }
        let images = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        try require(!images.contains(where: { $0.contains("QueryCraftSSHTerminalRenderer") }), "headless installation loaded the UI")
        // The host has no SwiftTerm dependency. Its UI is created entirely by
        // the signed plugin through opaque C handles and a borrowed NSView.
        let pluginURL = current.appending(path: "QueryCraftSSH.bundle")
        try SSHPlugin.validateTerminalRenderer(in: pluginURL)
        let renderer = try SSHTerminalSurface(bundleURL: pluginURL)
        renderer.feed(Array("\u{1b}[?2004h".utf8)[...])
        try require(renderer.inputFlags == 1, "bracketed paste capability query missing")
        renderer.feed(Array("\u{1b}[?1049h".utf8)[...])
        try require(renderer.inputFlags == 3, "alternate-screen input guard missing")
        renderer.feed(Array("\u{1b}[?1049l\u{1b}[?2004l".utf8)[...])
        try require(renderer.inputFlags == 0, "input mode reset was not observed")
        let unicode = Array("\u{1b}[2J\u{1b}[H插件终端 Renderer ABI".utf8)
        for byte in unicode { renderer.feed([byte][...]) }
        try require(renderer.visibleText.contains("插件终端 Renderer ABI"), "renderer Unicode/ANSI C ABI failed: \(renderer.visibleText)")
        renderer.appearance(dark: true); renderer.appearance(dark: false)
        let originalColumns = renderer.columns
        renderer.view.setFrameSize(NSSize(width: 600, height: 400))
        try require(renderer.columns > 1 && renderer.rows > 1 && renderer.columns != originalColumns, "renderer resize ABI failed")
        do { _ = try SSHTerminalSurface(bundleURL: root.appending(path: "missing.bundle")); throw TerminalUIFailure(message: "missing renderer accepted") }
        catch let failure as MCPFailure { try require(failure.code == .unsupported, "missing-renderer error is incorrect") }
        let changed = root.appending(path: "update/QueryCraftSSH.bundle")
        try FileManager.default.createDirectory(at: changed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pluginURL, to: changed)
        do { _ = try SSHTerminalSurface(bundleURL: changed); throw TerminalUIFailure(message: "second UI module version loaded") }
        catch let failure as MCPFailure { try require(failure.code == .sessionBusy, "renderer update must require restart") }
        renderer.feed(Array("\r\nOLD_RENDERER_ALIVE".utf8)[...])
        try require(renderer.visibleText.contains("OLD_RENDERER_ALIVE"), "existing renderer was disturbed by an update")
        let service = SSHConnectionService(directory: root)
        let preferenceName = "qc-terminal-preview-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer { preferences.removePersistentDomain(forName: preferenceName) }
        let model = SSHTerminalWorkspace(service: service, preferences: preferences)
        await model.reload(); model.selectServer(profile.id)
        await model.scripts.load()
        try require(model.inspectorTab == .scripts, "scripts must be the first/default inspector tab")
        try await render(SSHTerminalWorkspaceView(model: model), dark: false, width: 1100, height: 720, to: output.appending(path: "landing-light.png"))
        if ProcessInfo.processInfo.environment["QC_TERMINAL_SNAPSHOT_ONLY"] == "1" { return }
        // Reproduce first-open navigation while the sidebar's initial load is busy.
        model.accounts.profiles = []; model.accounts.loaded = false; model.accounts.busy = true
        model.openConnection(profile)
        let session = model.current!
        model.openConnection(profile)
        try require(model.sessions.count == 1 && model.current === session, "repeated home open duplicated a connecting session")
        model.accounts.busy = false
        await model.reload()
        try await wait { session.state != .connecting }
        try require(session.state == .connected, "real terminal failed: \(session.message)")
        model.openConnection(profile)
        try require(model.sessions.count == 1 && model.current === session, "home open did not reuse the connected session")
        print("PASS home open starts while account list is loading; repeated open reuses connecting/connected session")
        if ProcessInfo.processInfo.environment["QC_SCRIPT_LEGACY_ONLY"] == "1" {
            session.send(Data("stty -echo; PS1='legacy $ '; printf '\\nLEGACY_READY\\n'\r".utf8))
            try await wait { screen(session).split(separator: "\n").contains("LEGACY_READY") }
            try require(session.surface?.inputFlags == 0, "legacy fixture unexpectedly enabled paste mode")
            let short = try ShellScriptStore(directory: root).create(name: "short", description: "", script: "printf '%s' LEGACY_UI_OK > " + SSHTaskCommand.shellQuote(longMarker.path))
            model.useScript(short, execute: false)
            try await wait { !model.scriptDispatching }
            try require(model.scripts.error == nil, "legacy short insertion failed")
            try await Task.sleep(for: .milliseconds(200))
            try require(!FileManager.default.fileExists(atPath: longMarker.path), "legacy short insertion executed early")
            session.send(Data([13]))
            try await wait { FileManager.default.fileExists(atPath: longMarker.path) }
            try FileManager.default.removeItem(at: longMarker)
            model.useScript(longScript, execute: false)
            try await wait { !model.scriptDispatching }
            try require(model.scripts.error != nil && !FileManager.default.fileExists(atPath: longMarker.path), "unsafe legacy bulk input was not rejected")
            print("PASS legacy shell: short insertion waits for Return; unsupported bulk paste rejected before input")
            model.disconnectAll(); return
        }
        session.send(Data("exec /bin/zsh -f\r".utf8))
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        session.send(Data("stty -echo; PS1='querycraft $ '; printf '\\nUI_NATIVE_READY\\n'\r".utf8))
        try await wait { screen(session).split(separator: "\n").contains("UI_NATIVE_READY") }
        session.send(Data("cd /tmp; printf 'UI_CWD='; pwd; printf '\\033[32mPTY connected\\033[0m\\n'; stty size\r".utf8))
        try await wait { screen(session).contains("UI_CWD=/tmp") }
        try require(screen(session).contains("UI_CWD=/tmp"), "cd did not persist through actual Swift UI/session/socket/plugin: state=\(session.state) message=\(session.message) screen=\(screen(session))")
        for dark in [false, true] {
            try await render(SSHTerminalWorkspaceView(model: model), dark: dark, width: 1100, height: 720, to: output.appending(path: "connected-\(dark ? "dark" : "light").png"))
        }
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        model.useScript(savedScript, execute: false)
        try await wait { !model.scriptDispatching }
        try require(model.scripts.error == nil && !model.scripts.status.isEmpty, "script insertion failed: " + (model.scripts.error ?? "no send status"))
        try await Task.sleep(for: .milliseconds(200))
        try require(!FileManager.default.fileExists(atPath: scriptMarker.path), "insertion unexpectedly executed without Return")
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        model.useScript(savedScript, execute: true)
        try await wait { !model.scriptDispatching && FileManager.default.fileExists(atPath: scriptMarker.path) }
        let scriptOutput = try String(contentsOf: scriptMarker, encoding: .utf8)
        try require(scriptOutput == "a'b 中文", "multiline script bytes changed")
        try FileManager.default.removeItem(at: scriptMarker)
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        model.useScript(savedScript, execute: true)
        try await wait { !model.scriptDispatching && FileManager.default.fileExists(atPath: scriptMarker.path) }
        try require(session.state == .connected && screen(session).contains("UI_CWD=/tmp"), "saved script disturbed persistent terminal")
        try FileManager.default.removeItem(at: scriptMarker)
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        model.useScript(savedScript, execute: false)
        try await wait { !model.scriptDispatching }
        try await Task.sleep(for: .milliseconds(100))
        try require(!FileManager.default.fileExists(atPath: scriptMarker.path), "second insertion unexpectedly executed")
        session.send(Data([13]))
        try await wait { FileManager.default.fileExists(atPath: scriptMarker.path) }
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        model.useScript(longScript, execute: false)
        try await wait { !model.scriptDispatching }
        try require(model.scripts.error == nil, "large script insertion failed")
        try await Task.sleep(for: .seconds(2))
        try require(!FileManager.default.fileExists(atPath: longMarker.path), "large script ran before Return")
        session.send(Data([13]))
        try await wait { FileManager.default.fileExists(atPath: longMarker.path) }
        let longOutput = try String(contentsOf: longMarker, encoding: .utf8)
        try require(longOutput == "LARGE_UI_OK", "large terminal script was truncated or changed")
        try await wait { session.surface?.inputFlags.map { $0 & 3 == 1 } == true }
        session.send(Data("printf 'UI_CWD='; pwd\r".utf8))
        try await wait { screen(session).contains("UI_CWD=/tmp") }
        try await render(SSHTerminalWorkspaceView(model: model), dark: true, width: 1200, height: 780, to: output.appending(path: "saved-script-list.png"))
        model.inspectorTab = .connection
        try await render(SSHTerminalWorkspaceView(model: model), dark: true, width: 1200, height: 780, to: output.appending(path: "connection-info-tab.png"))
        model.inspectorTab = .scripts
        let originalSurface = model.current?.surface
        let originalSession = model.current
        model.setSidebarVisible(false)
        try await render(SSHTerminalWorkspaceView(model: model), dark: true, width: 960, height: 520, to: output.appending(path: "sidebar-hidden.png"))
        model.setInspectorVisible(false)
        try await render(SSHTerminalWorkspaceView(model: model), dark: true, width: 800, height: 480, to: output.appending(path: "connected-narrow.png"))
        model.setSidebarVisible(true)
        model.setInspectorVisible(true)
        try await render(SSHTerminalWorkspaceView(model: model), dark: true, width: 1100, height: 720, to: output.appending(path: "panes-restored.png"))
        try require(model.current === originalSession && model.current?.surface === originalSurface, "pane toggles replaced terminal/session")
        try require(model.current?.state == .connected, "pane toggles disconnected terminal")
        try require(screen(session).contains("UI_CWD=/tmp"), "resize lost prior terminal content")
        // Exercise a full-screen app over the actual UI transport without keyboard simulation.
        session.send(Data("vim -Nu NONE -n -i NONE /dev/null\r".utf8)); try await Task.sleep(for: .milliseconds(300))
        session.send(Data("iQUERYCRAFT_VIM".utf8)); try await Task.sleep(for: .milliseconds(100))
        try require(screen(session).contains("QUERYCRAFT_VIM"), "vim input/alternate screen failed")
        do { try session.insertScript(savedScript.script, execute: false); throw TerminalUIFailure(message: "script pasted into full-screen editor") }
        catch is MCPFailure { /* The current renderer advertises alternate-screen mode. */ }
        session.send(Data([27]) + Data(":q!\r".utf8)); try await Task.sleep(for: .milliseconds(150))
        try await verifyOutputAndWheel(session, root: root)
        session.send(Data("sleep 20\r".utf8)); try await Task.sleep(for: .milliseconds(100)); session.send(Data([3]))
        try await Task.sleep(for: .milliseconds(100)); session.send(Data("printf 'UI_CTRL_C_OK\\n'\r".utf8))
        try await Task.sleep(for: .milliseconds(250))
        try require(screen(session).contains("UI_CTRL_C_OK"), "Ctrl-C failed through UI transport")
        model.connect(profile); let second = model.current!; try await wait { second.state != .connecting }
        try require(second.state == .connected && session.state == .connected, "parallel tab sessions failed")
        model.connect(profile); let third = model.current!; try await wait { third.state != .connecting }
        try require(third.state == .connected, "third terminal tab failed")
        for dark in [false, true] {
            try await render(SSHTerminalWorkspaceView(model: model), dark: dark, width: 1200, height: 780, to: output.appending(path: "three-tabs-\(dark ? "dark" : "light").png"))
        }
        model.selectSession(session.id)
        try require(screen(session).contains("UI_CTRL_C_OK"), "tab selection lost terminal content")
        session.disconnect(); second.disconnect(); third.disconnect(); try await wait { !model.hasActiveSessions }
        try await render(SSHTerminalWorkspaceView(model: model), dark: true, width: 1100, height: 720, to: output.appending(path: "disconnected-retains-content.png"))
        model.reconnect(session); let reconnected = model.current!; try await wait { reconnected.state != .connecting }
        try require(reconnected.state == .connected, "reconnect failed")
        model.disconnectAll(); try await wait { !model.hasActiveSessions }
        // Stable empty/loading/error/failed states with no user data or network access.
        let blankRoot = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: blankRoot, withIntermediateDirectories: true)
        let empty = SSHTerminalWorkspace(service: SSHConnectionService(directory: blankRoot)); await empty.reload()
        try await render(SSHTerminalWorkspaceView(model: empty), dark: false, width: 800, height: 480, to: output.appending(path: "empty.png"))
        model.accounts.error = "Preview: temporary account-load failure"
        try await render(SSHTerminalWorkspaceView(model: model), dark: false, width: 800, height: 480, to: output.appending(path: "error-retains-content.png"))
        print("PASS signed plugin renderer C ABI, lazy load, Unicode/ANSI, resize, existing view retained across rejected second module; native SSH UI: Chinese/English light/dark/narrow; real libssh2 PTY, cd, vim/alternate-screen, Ctrl-C, parallel tabs/content retention, disconnect/reconnect; no physical input simulation")
    }
    @MainActor static func verifyOutputAndWheel(_ session: SSHTerminalSession, root: URL) async throws {
        // Directly deliver an event to this isolated native view; never post desktop input.
        func wheelDown() throws {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                      wheel1: -3, wheel2: 0, wheel3: 0),
                  let native = NSEvent(cgEvent: event), let view = session.surface?.view else {
                throw TerminalUIFailure(message: "Cannot construct isolated wheel event")
            }
            view.scrollWheel(with: native)
        }
        let clock = ContinuousClock()
        let start = clock.now
        var maximumGap: Duration = .zero
        var last = start
        session.send(Data("awk 'BEGIN { for(i=0;i<30000;i++) printf \"OUTPUT_%05d 中文\\n\",i; print \"OUTPUT_COMPLETE\" }'\r".utf8))
        for _ in 0..<1500 {
            try await Task.sleep(for: .milliseconds(10))
            let now = clock.now
            maximumGap = max(maximumGap, last.duration(to: now)); last = now
            if screen(session).split(separator: "\n").contains("OUTPUT_COMPLETE") { break }
        }
        try require(screen(session).contains("OUTPUT_29999"), "Large PTY output lost its final line")
        try require(screen(session).split(separator: "\n").contains("OUTPUT_COMPLETE"), "Large PTY output did not finish")
        try require(maximumGap < .milliseconds(250), "Main actor stalled during output: \(maximumGap)")
        print("PASS 30000-line PTY output; elapsed=\(start.duration(to: clock.now)), max main-actor heartbeat gap=\(maximumGap)")
        let file = root.appending(path: "wheel-input.txt")
        let result = root.appending(path: "wheel-result.txt")
        try (1...500).map { "line_\($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        for mouse in [false, true] {
            try? FileManager.default.removeItem(at: result)
            session.send(Data(("vim -Nu NONE -n -i NONE -c 'set mouse=" + (mouse ? "a" : "") + "' " + SSHTaskCommand.shellQuote(file.path) + "\r").utf8))
            try await wait { session.surface?.inputFlags.map { $0 & 2 != 0 } == true }
            try await Task.sleep(for: .milliseconds(200))
            try wheelDown()
            try await Task.sleep(for: .milliseconds(300))
            session.send(Data((":call writefile([string(line('.')), string(line('w0'))], '" + result.path + "')\r").utf8))
            try await wait { (try? String(contentsOf: result, encoding: .utf8).split(separator: "\n").count) == 2 }
            let positions = try String(contentsOf: result, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
            try require(positions.contains { $0 > 1 }, "Vim did not scroll; mouse=\(mouse), positions=\(positions)")
            session.send(Data(":q!\r".utf8))
            try await wait { session.surface?.inputFlags.map { $0 & 2 == 0 } == true }
            print("PASS real Vim isolated wheel; mouse=\(mouse), cursor/viewport=\(positions)")
        }
    }

    @MainActor static func live(host: String, directory: URL) async throws {
        let service = SSHConnectionService(directory: directory)
        let saved = try await service.snapshot().profiles
        guard let profile = saved.first(where: { $0.host == host }) else { throw TerminalUIFailure(message: "Authorized saved Dev host was not found") }
        let session = SSHTerminalSession(profile: profile); session.start(service: service)
        defer { session.disconnect() }
        print("LIVE connecting")
        try await wait { session.state != .connecting }
        print("LIVE connection state=\(session.state) message=\(session.message)")
        try require(session.state == .connected, "live connection failed: \(session.message)")
        print("LIVE shell ready")
        session.send(Data("stty -echo; printf '\\nQC_LIVE_READY\\n'\r".utf8))
        try await wait { screen(session).split(separator: "\n").contains("QC_LIVE_READY") }
        print("LIVE initial marker received")
        session.send(Data("cd /tmp; printf 'QC_LIVE_CWD='; pwd\r".utf8))
        try await wait { screen(session).contains("QC_LIVE_CWD=/tmp") }
        print("LIVE cd verified")
        session.send(Data("command -v vim >/dev/null 2>&1 || printf 'QC_NO_VIM\\n'; printf 'QC_COMMAND_CHECK\\n'\r".utf8))
        try await wait { screen(session).split(separator: "\n").contains("QC_COMMAND_CHECK") }
        let hasVim = !screen(session).contains("QC_NO_VIM")
        if hasVim {
        session.send(Data("vim -Nu NONE -n -i NONE /dev/null\r".utf8))
        try await Task.sleep(for: .milliseconds(400)); session.send(Data("iQC_LIVE_VIM".utf8))
        try await wait { screen(session).contains("QC_LIVE_VIM") }
        session.send(Data([27]) + Data(":q!\r".utf8)); try await Task.sleep(for: .milliseconds(200))
        print("LIVE vim verified")
        } else { print("LIVE vim unavailable on this server; full-screen vim already verified on loopback") }
        session.send(Data("top -d 1\r".utf8))
        do { try await wait { screen(session).localizedCaseInsensitiveContains("load average") || screen(session).contains("Tasks:") } }
        catch { throw TerminalUIFailure(message: "Live top check failed. Screen: \(screen(session))") }
        session.send(Data("q".utf8)); try await Task.sleep(for: .milliseconds(200))
        session.send(Data("printf '\\nQC_LIVE_OK\\n'\r".utf8))
        try await wait { screen(session).split(separator: "\n").contains("QC_LIVE_OK") }
        session.disconnect(); try await wait { !session.isActive }
        print("PASS authorized saved Dev account: shared Keychain/pin, persistent cd, available full-screen programs, normal shell recovery and disconnect; no remote installation")
    }
    @MainActor static func screen(_ session: SSHTerminalSession) -> String {
        session.surface?.visibleText ?? ""
    }
    @MainActor static func nativeSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let split = nativeSplit(in: child) { return split } }
        return nil
    }
    @MainActor static func render<V: View>(_ view: V, dark: Bool, width: CGFloat, height: CGFloat, to url: URL) async throws {
        print("RENDER " + url.lastPathComponent); fflush(stdout)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        controller.sizingOptions = []
        let host = controller.view
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let toolbar = (view as? SSHTerminalWorkspaceView).map { SSHTerminalWindowToolbar(model: $0.model) }
        window.toolbarStyle = .automatic; window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden; window.titlebarSeparatorStyle = .none
        window.toolbar = toolbar?.managedToolbar
        if ProcessInfo.processInfo.environment["QC_CAPTURE_COMPOSITOR"] == "1" { window.center() }
        window.contentViewController = controller; window.setContentSize(NSSize(width: width, height: height)); host.frame = NSRect(x: 0, y: 0, width: width, height: height); window.orderBack(nil)
        defer { (nativeSplit(in: host)?.delegate as? WorkspaceMainSplitViewController)?.invalidate(); toolbar?.invalidate(); window.orderOut(nil); window.contentViewController = nil; window.toolbar = nil; window.close() }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(800)); window.setContentSize(NSSize(width: width, height: height)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        if url.lastPathComponent == "panes-restored.png", let workspace = view as? SSHTerminalWorkspaceView {
            let session = workspace.model.current
            let surface = session?.surface
            guard let split = nativeSplit(in: host), let splitController = split.delegate as? WorkspaceMainSplitViewController, splitController.splitViewItems.count == 3 else { throw TerminalUIFailure(message: "native three-column split missing") }
            for _ in 0..<3 {
                workspace.model.toggleSidebar(); workspace.model.toggleInspector()
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                try require(splitController.splitViewItems[0].isCollapsed && splitController.splitViewItems[2].isCollapsed, "native pane collapse did not follow model")
                workspace.model.toggleSidebar(); workspace.model.toggleInspector()
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                try require(!splitController.splitViewItems[0].isCollapsed && !splitController.splitViewItems[2].isCollapsed, "native pane restore did not follow model")
            }
            try require(workspace.model.current === session && session?.surface === surface && session?.state == .connected, "live pane toggles replaced/disconnected terminal")
            try require(surface?.view.window === window, "live pane toggles detached terminal view")
            guard let session else { throw TerminalUIFailure(message: "live layout session missing") }
            let expectedSize = "UI_LAYOUT_SIZE=" + String(session.rows) + " " + String(session.columns)
            session.send(Data("printf 'UI_LAYOUT_ALIVE\\nUI_LAYOUT_SIZE='; stty size\r".utf8))
            try await wait { screen(session).contains("UI_LAYOUT_ALIVE") && screen(session).contains(expectedSize) }
        }
        if url.lastPathComponent == "landing-light.png" { try require(window.toolbar?.items.map(\.itemIdentifier) == SSHTerminalWindowToolbar.defaultItemIdentifiers, "native toolbar actions missing") }
        if ProcessInfo.processInfo.environment["QC_CAPTURE_COMPOSITOR"] == "1" {
            try require(CGPreflightScreenCaptureAccess(), "Screen capture not already authorized; no permission prompt requested")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let capturedWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw TerminalUIFailure(message: "Preview window unavailable to compositor") }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: capturedWindow), configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TerminalUIFailure(message: "no compositor PNG") }
            try png.write(to: url); return
        }
        let capture = host
        guard let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { throw TerminalUIFailure(message: "no bitmap") }
        capture.cacheDisplay(in: capture.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TerminalUIFailure(message: "no PNG") }
        try png.write(to: url)
    }
}
