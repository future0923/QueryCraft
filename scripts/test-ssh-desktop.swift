import AppKit
import CryptoKit
import Foundation
import SwiftUI
@testable import QueryCraftFeature

struct SSHDesktopFailure: Error { let message: String }
func requireSSH(_ condition: Bool, _ message: String) throws {
    if !condition { throw SSHDesktopFailure(message: message) }
}

@main struct SSHDesktopCheck {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments, fm = FileManager.default
        let root = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let archive = URL(fileURLWithPath: args[3]), mcp = URL(fileURLWithPath: args[4])
        let base = URL(string: args[5])!, serving = output.appending(path: "catalog")
        try fm.createDirectory(at: serving, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        let catalog = MCPComponentCatalog(baseURL: base, publicKey: key.publicKey.rawRepresentation, allowsLocalHTTP: true)
        let manager = SSHPluginManager(directory: root, catalog: catalog)
        let previousPath = ProcessInfo.processInfo.environment["QUERYCRAFT_TEST_SSH_PREVIOUS_PACKAGE"] ?? ""
        var previousRelease: MCPComponentRelease?
        if !previousPath.isEmpty {
            let previous = URL(fileURLWithPath: previousPath)
            try await manager.importPackage(previous)
            let oldBundle = Bundle(url: SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath())!
            let oldDownload = serving.appending(path: "previous.zip")
            try fm.copyItem(at: previous, to: oldDownload)
            previousRelease = MCPComponentRelease(component: .ssh,
                version: oldBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String,
                build: oldBundle.object(forInfoDictionaryKey: "CFBundleVersion") as! String,
                architectures: [DatabaseDriverArchitecture.current.rawValue], minimumAppVersion: "0.0.0", maximumAppVersionExclusive: nil,
                driverAPI: 5, storageAPI: 1, credentialAPI: 1, desktopAPI: 1, minimumMCPVersion: nil, maximumMCPVersionExclusive: nil,
                sha256: try MCPComponentCatalog.sha256(oldDownload), size: (try fm.attributesOfItem(atPath: oldDownload.path)[.size] as! NSNumber).int64Value,
                url: base.appending(path: "previous.zip"))
        }
        // Inspect the new package in a separate installer, leaving the old Current active until online update.
        let inspection = SSHPluginManager(directory: root.appending(path: "inspect"), catalog: catalog)
        try await inspection.importPackage(archive)
        if previousRelease == nil { try await manager.importPackage(archive) }
        let installedVersion = try await inspection.installedVersion()
        try requireSSH(installedVersion != nil, "local signed ZIP was not loaded")
        let bundle = SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath()
        let download = serving.appending(path: "ssh.zip")
        if fm.fileExists(atPath: download.path) { try fm.removeItem(at: download) }
        try fm.copyItem(at: archive, to: download)
        let metadataURL = SSHPlugin.bundleURL(in: root.appending(path: "inspect")).appending(path: "Contents/Resources/component.json")
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        metadata["sha256"] = try MCPComponentCatalog.sha256(download)
        metadata["size"] = (try fm.attributesOfItem(atPath: download.path)[.size] as! NSNumber).int64Value
        metadata["url"] = base.appending(path: "ssh.zip").absoluteString
        let release = try JSONDecoder().decode(MCPComponentRelease.self, from: JSONSerialization.data(withJSONObject: metadata))
        let catalogFile = serving.appending(path: "ssh-\(DatabaseDriverArchitecture.current.rawValue).json")
        func publish(corrupt: Bool = false) throws {
            let payload = try JSONEncoder().encode(release)
            let envelope = MCPComponentCatalog.Envelope(payload: payload,
                signature: corrupt ? Data(repeating: 0, count: 64) : try key.signature(for: payload))
            try JSONEncoder().encode(MCPComponentCatalog.Catalog(schemaVersion: 1, component: .ssh, releases: [envelope]))
                .write(to: catalogFile, options: .atomic)
        }
        try publish()
        let selected = try await manager.available()
        try await manager.install(release: selected) { _ in }
        let active = SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath()
        try requireSSH(active != bundle, "download did not install an immutable new version")
        try requireSSH(try await manager.installedVersion() == installedVersion, "online update did not select the new version")
        if let previousRelease {
            do { try await manager.install(release: previousRelease) { _ in }; throw SSHDesktopFailure(message: "online downgrade accepted") }
            catch is MCPFailure {}
            try requireSSH(SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath() == active, "downgrade replaced Current")
        }
        if previousRelease != nil {
            // The manager's initial snapshot is not sufficient: activation itself
            // must reject a stale candidate against Current under the install lock.
            do {
                _ = try SSHPluginInstallation.install(source: bundle, directory: root, preventsDowngrade: true)
                throw SSHDesktopFailure(message: "activation accepted a stale candidate")
            } catch let error as MCPFailure {
                try requireSSH(error.message.contains("downgrade"), "activation rejected stale candidate for the wrong reason")
            }
            try requireSSH(SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath() == active, "stale activation displaced Current")
        }
        var mismatched = metadata
        mismatched["maximumAppVersionExclusive"] = "99.0.0"
        let wrongRelease = try JSONDecoder().decode(MCPComponentRelease.self, from: JSONSerialization.data(withJSONObject: mismatched))
        do { try await manager.install(release: wrongRelease) { _ in }; throw SSHDesktopFailure(message: "mismatched signed compatibility accepted") }
        catch let error as MCPFailure {
            try requireSSH(error.message.contains("compatibility metadata"), "mismatch was rejected for the wrong reason")
        }
        try requireSSH(SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath() == active, "metadata mismatch replaced Current")
        try publish(corrupt: true)
        do { _ = try await manager.available(); throw SSHDesktopFailure(message: "forged catalog accepted") }
        catch is MCPFailure {}
        try Data("corrupt package".utf8).write(to: download)
        do { try await manager.install(release: selected) { _ in }; throw SSHDesktopFailure(message: "bad package accepted") }
        catch is MCPFailure {}
        try requireSSH(SSHPlugin.bundleURL(in: root).resolvingSymlinksInPath() == active, "failed download displaced installed plugin")
        try await manager.uninstall()
        try requireSSH(try await manager.installedVersion() == nil, "uninstall left plugin active")
        try await manager.importPackage(archive)
        print("PASS signed local ZIP, signed architecture catalog, download, immutable activation, signature/checksum rejection and uninstall/reinstall")

        if ProcessInfo.processInfo.environment["QUERYCRAFT_TEST_SSH_DISTRIBUTION_ONLY"] == "1" { return }

        let service = SSHConnectionService(directory: root)
        let model = SSHSettingsModel(service: service)
        await model.load()
        try requireSSH(model.loaded && model.profiles.isEmpty, "initial empty load failed")
        let fixture = SSHConnection(id: UUID(), name: "Linux · 测试服务器", host: "192.168.0.33", port: 22, username: "root",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), storesCredential: true)
        let previewModel = SSHSettingsModel(service: service)
        previewModel.loaded = true; previewModel.profiles = [fixture]; previewModel.policy.enabled = true
        SSHAccess.connect.apply(id: fixture.id, to: &previewModel.policy)
        try SSHConnectionStore(directory: root).insert(fixture)
        try MCPPolicyStore(directory: root).save(previewModel.policy)
        let previewJump = SSHConnection(id: UUID(), name: "bastion", host: "10.0.0.1", port: 22, username: "admin",
            hostFingerprint: fixture.hostFingerprint, privateKeyPath: "/Users/demo/.ssh/id_ed25519", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(previewJump)
        let pluginModel = SSHPluginSettingsModel(manager: manager)
        pluginModel.installed = installedVersion; pluginModel.checked = true; pluginModel.availabilityError = "No development source configured"
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await render(SSHSettingsPane(model: previewModel), dark: dark, width: 500, height: 730, to: output.appending(path: "servers-\(suffix).png"))
            try await render(Form { MCPSSHAccessSection(directory: root) }.formStyle(.grouped), dark: dark,
                width: 650, height: 430, to: output.appending(path: "mcp-ssh-access-\(suffix).png"))
            try await render(SSHAccessEditor(profile: fixture, service: service), dark: dark,
                width: 540, height: 480, to: output.appending(path: "access-editor-\(suffix).png"))
            let draft = SSHConnectionDraft(profile: fixture, policy: previewModel.policy)
            try await render(SSHConnectionEditor(draft: draft, service: service), dark: dark, width: 620, height: 730, to: output.appending(path: "password-\(suffix).png"))
            try await render(SSHConnectionEditor(draft: draft, service: service), dark: dark, width: 620, height: 730, to: output.appending(path: "permissions-\(suffix).png"), bottom: true)
            draft.authentication = .privateKey; draft.keyPath = "/Users/demo/.ssh/id_ed25519"; draft.keyHasPassphrase = true
            try await render(SSHConnectionEditor(draft: draft, service: service), dark: dark, width: 620, height: 730, to: output.appending(path: "key-\(suffix).png"))
            draft.authentication = .agent; draft.agentSocketPath = "/tmp/example-agent.sock"; draft.jumpConnectionID = previewJump.id
            try await render(SSHConnectionEditor(draft: draft, service: service), dark: dark, width: 620, height: 730, to: output.appending(path: "agent-jump-\(suffix).png"))
            let config = root.appending(path: "preview-ssh-config")
            try "Host bastion\n HostName 10.0.0.1\n User admin\n IdentityFile ~/.ssh/id_ed25519\nHost app\n HostName app.internal\n User deploy\n ProxyJump bastion\n".write(to: config, atomically: true, encoding: .utf8)
            let importing = SSHConfigImportModel(); importing.path = config.path
            await importing.load(service: service); importing.selection = "app"
            try await render(SSHConfigImportPane(service: service, model: importing), dark: dark, width: 780, height: 650, to: output.appending(path: "config-import-\(suffix).png"))
            try await render(Form { SSHPluginSettingsSection(model: pluginModel) }.formStyle(.grouped), dark: dark,
                width: 500, height: 420, to: output.appending(path: "plugin-\(suffix).png"))
        }
        try SSHConnectionStore(directory: root).remove(id: previewJump.id)
        let task = SSHTaskRecord(id: UUID(), connectionID: fixture.id, binding: SSHTaskRecord.binding(fixture), createdAt: Date(timeIntervalSince1970: 1_761_200_000))
        let transferID = UUID(), remote = "/srv/releases/archive.tar.gz"
        let transfer = SSHTransferRecord(id: transferID, connectionID: fixture.id, binding: SSHTaskRecord.binding(fixture), upload: true,
            remotePath: remote, localPath: "/Users/example/Downloads/archive.tar.gz",
            stagingPath: SSHTransferRecord.stagingPath(destination: remote, id: transferID), createdAt: task.createdAt, cancellationVersion: 1)
        let activitySnapshot = SSHActivitySnapshot(tasks: [task], transfers: [.init(record: transfer, active: false, cancellationRequested: false)],
            allowedTools: MCPToolCatalog.sshTools, policyEnabled: true, pluginAvailable: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let preview = SSHActivityModel(profile: fixture, service: SSHActivityPreviewService(value: activitySnapshot))
            await preview.refreshList(); preview.select(.task(task.id)); await preview.refreshDetail()
            try await render(SSHActivityPanel(model: preview), dark: dark, width: 920, height: 650,
                to: output.appending(path: "activity-task-\(suffix).png"))
            preview.select(.transfer(transfer.id)); await preview.refreshDetail()
            try await render(SSHActivityPanel(model: preview), dark: dark, width: 780, height: 650,
                to: output.appending(path: "activity-transfer-narrow-\(suffix).png"))
            let confirm = SSHActivityConfirmation(action: .cleanupTransfer, selection: .transfer(transfer.id), inspectionToken: preview.inspectionToken, transfer: transfer)
            try await render(SSHActivityConfirmationSheet(model: preview, confirmation: confirm), dark: dark, width: 588, height: 490,
                to: output.appending(path: "activity-confirmation-\(suffix).png"))
        }
        let empty = SSHActivityModel(profile: fixture, service: SSHActivityPreviewService(value: SSHActivitySnapshot()))
        await empty.refreshList()
        try await render(SSHActivityPanel(model: empty), dark: false, width: 780, height: 600, to: output.appending(path: "activity-empty.png"))
        let loading = SSHActivityModel(profile: fixture, service: SSHActivityPreviewService(value: activitySnapshot, delay: true))
        try await render(SSHActivityPanel(model: loading), dark: false, width: 780, height: 600, to: output.appending(path: "activity-loading.png"))
        let failed = SSHActivityModel(profile: fixture, service: SSHActivityPreviewService(value: activitySnapshot, fails: true))
        failed.snapshot = activitySnapshot; await failed.refreshList()
        try await render(SSHActivityPanel(model: failed), dark: true, width: 780, height: 600, to: output.appending(path: "activity-error-retained.png"))
        print("PASS native activity task/log, transfer/inspection, confirmation, narrow, initial loading, empty and retained-error layouts")
        previewModel.busy = true
        try await render(SSHSettingsPane(model: previewModel), dark: true, width: 500, height: 730, to: output.appending(path: "servers-loading.png"))
        print("PASS offscreen native light/dark server, password/key editor and plugin layouts; no desktop input")
        try SSHConnectionStore(directory: root).remove(id: fixture.id)
        try MCPPolicyStore(directory: root).update { SSHAccess.denied.apply(id: fixture.id, to: &$0) }

        if args.count > 8 {
            let secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let live = SSHConnection(id: UUID(), name: "Temporary desktop account test", host: args[6], port: 22,
                username: args[7], hostFingerprint: args[8], storesCredential: true)
            let scanned = try await service.fingerprint(host: live.host, port: live.port)
            try requireSSH(scanned == live.hostFingerprint, "scan does not match independently verified host fingerprint")
            try await service.save(live, original: nil, secret: secret, access: .execute)
            do {
                try await service.test(live, secret: nil)
                var edited = live; edited.name = "Edited desktop account"
                try await service.save(edited, original: live, secret: nil, access: .execute)
                try MCPPolicyStore(directory: root).update { $0.enabled = true; $0.mode = .fullAccess }
                try await Task.detached { try stdioCheck(mcp: mcp, root: root, id: live.id) }.value
                try await activityLiveCheck(root: root, profile: edited)
                let profiles = try SSHConnectionStore(directory: root).load()
                try requireSSH(!String(decoding: try Data(contentsOf: root.appending(path: "ssh-connections.json")), as: UTF8.self).contains(secret), "secret entered profile JSON")
                try await service.remove(profiles.first(where: { $0.id == live.id })!)
                try requireSSH(try await MCPCredentialStore(directory: root).password(for: live.id) == nil, "credential retained after deletion")
            } catch {
                if let current = try? SSHConnectionStore(directory: root).load().first(where: { $0.id == live.id }) { try? await service.remove(current) }
                throw error
            }
            print("PASS real desktop account Keychain save/edit, fingerprint scan, saved-credential test, independent MCP stdio lookup/command, delete and credential cleanup")
        }
    }
    @MainActor static func activityLiveCheck(root: URL, profile: SSHConnection) async throws {
        let service = SSHActivityService(directory: root, profile: profile)
        let started = try await service.call("ssh_start_task", arguments: ["command": "printf activity-panel-ok; sleep 30", "confirm_high_risk": true])
        guard let text = started.objectValue?["task_id"]?.stringValue, let id = UUID(uuidString: text) else { throw SSHDesktopFailure(message: "native task did not start") }
        do {
            let model = SSHActivityModel(profile: profile, service: service)
            await model.refreshList(); model.select(.task(id)); await model.refreshDetail()
            for _ in 0..<10 where !model.log.contains("activity-panel-ok") {
                try await Task.sleep(for: .milliseconds(200)); await model.refreshDetail()
            }
            try requireSSH(model.snapshot?.tasks.contains { $0.id == id } == true, "native registry missing task")
            try requireSSH(model.log.contains("activity-panel-ok"), "native log byte window failed; state=\(model.taskState), offset=\(model.nextOffset), error=\(model.detailError ?? "none")")
            let cancel = SSHActivityConfirmation(action: .cancelTask, selection: .task(id), inspectionToken: nil)
            try requireSSH(await model.perform(cancel, acknowledged: false), "native cancellation failed")
            for _ in 0..<25 {
                await model.refreshDetail()
                if model.terminalTask { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            try requireSSH(model.taskState == "cancelled", "native task not cancelled")
            let remove = SSHActivityConfirmation(action: .removeTask, selection: .task(id), inspectionToken: nil)
            try requireSSH(await model.perform(remove, acknowledged: false), "native terminal cleanup failed")
            try requireSSH(!SSHTaskStore(directory: root).load().contains { $0.id == id }, "native task record retained")
            let destination = root.appending(path: "native-destination"), transferID = UUID()
            try Data("preserved".utf8).write(to: destination)
            let staging = SSHTransferRecord.stagingPath(destination: destination.path, id: transferID)
            try Data("partial".utf8).write(to: URL(fileURLWithPath: staging))
            try MCPPolicyStore(directory: root).update { $0.ssh?.fileTransferConnectionIDs.insert(profile.id) }
            let record = SSHTransferRecord(id: transferID, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), upload: false,
                remotePath: "/unused-native-source", localPath: destination.path, stagingPath: staging, createdAt: Date())
            try SSHTransferStore(directory: root).insert(record)
            await model.refreshList(); model.select(.transfer(transferID)); await model.refreshDetail()
            try requireSSH(model.inspectionToken != nil, "native transfer inspection missing")
            let clean = SSHActivityConfirmation(action: .cleanupTransfer, selection: .transfer(transferID), inspectionToken: model.inspectionToken, transfer: record)
            try requireSSH(await model.perform(clean, acknowledged: true), "native staging cleanup failed")
            try requireSSH(try Data(contentsOf: destination) == Data("preserved".utf8), "native cleanup modified destination")
            try requireSSH(!FileManager.default.fileExists(atPath: staging), "native staging retained")
            await service.close()
        } catch {
            _ = try? await service.call("ssh_cancel_task", arguments: ["task_id": .string(id.uuidString), "confirm_high_risk": true])
            for _ in 0..<25 {
                if (try? await service.call("ssh_remove_task", arguments: ["task_id": .string(id.uuidString), "confirm_high_risk": true])) != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            await service.close(); throw error
        }
        print("PASS real native activity service/model: shared credential, live status/logs, cancel, terminal cleanup and token-checked staging cleanup preserving destination")
    }
    static func stdioCheck(mcp: URL, root: URL, id: UUID) throws {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = mcp; process.arguments = ["--stdio", "--data-dir", root.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
        func send(_ body: [String: Any], reply: Bool = true) throws -> [String: Any] {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body) + Data([10]))
            if !reply { return [:] }
            var line = Data()
            while let data = try output.fileHandleForReading.read(upToCount: 1), !data.isEmpty {
                if data[0] == 10 { break }; line.append(data)
            }
            return try JSONSerialization.jsonObject(with: line) as! [String: Any]
        }
        _ = try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "SSH desktop check", "version": "1"]]])
        _ = try send(["jsonrpc": "2.0", "method": "notifications/initialized"], reply: false)
        let reply = try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "querycraft_ssh_execute", "arguments": ["connection_id": id.uuidString, "command": "printf 'desktop-stdio-ok\\n'; id -u; uname -s", "confirm_high_risk": true]]])
        let result = reply["result"] as? [String: Any]
        try requireSSH(result?["isError"] as? Bool != true, "MCP could not use desktop credential")
        let value = result?["structuredContent"] as? [String: Any]
        try requireSSH((value?["stdout"] as? String)?.contains("desktop-stdio-ok") == true, "MCP SSH command failed")
    }
    @MainActor static func render<Content: View>(_ view: Content, dark: Bool, width: CGFloat, height: CGFloat, to url: URL, bottom: Bool = false) async throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: width, height: height); window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
        if bottom {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            if let scroll = scrollViews(host).first, let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.frame.height - scroll.contentSize.height) : 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
            }
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SSHDesktopFailure(message: "no bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}


private actor SSHActivityPreviewService: SSHActivityServing {
    let value: SSHActivitySnapshot
    var delay = false
    var fails = false
    init(value: SSHActivitySnapshot, delay: Bool = false, fails: Bool = false) { self.value = value; self.delay = delay; self.fails = fails }
    func snapshot() async throws -> SSHActivitySnapshot {
        if delay { try await Task.sleep(for: .seconds(60)) }
        if fails { throw MCPFailure("Connection unavailable. Existing records retained.") }
        return value
    }
    func call(_ tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        if tool == "ssh_task_status" { return .object(["state": "running", "stdout_bytes": 128, "stderr_bytes": 0]) }
        if tool == "ssh_task_output" {
            let offset = arguments["offset"]?.intValue ?? 0
            let bytes = offset == 0 ? Data("Starting deployment…\nChecking archive SHA256…\nWaiting for service health check…\n".utf8) : Data()
            return .object(["content_base64": .string(bytes.base64EncodedString()), "next_offset": .int(offset + bytes.count), "final": false])
        }
        return .object(["inspection_token": "preview-token", "metadata": .object([
            "staging": .object(["exists": true, "type": "file", "size_bytes": 8_388_608]),
            "destination": .object(["exists": false])])])
    }
    func cancelTransfer(_ id: UUID) {}
    func close() {}
}
