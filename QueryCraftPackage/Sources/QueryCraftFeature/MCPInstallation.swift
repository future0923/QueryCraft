import Foundation
import Security

actor MCPInstallation {
    static let shared = MCPInstallation()
    private var installing = false
    let root: URL
    private let identity: MCPServerIdentity
    private let localPackage: URL?
    let catalog: MCPComponentCatalog
    let host: MCPComponentHost
    private static let runtimeIDs: Set<String> = ["io.github.future0923.QueryCraft.MCP", "io.github.future0923.QueryCraft.MCP.Dev"]
    var appURL: URL {
        let current = root.appending(path: "Current")
        return FileManager.default.fileExists(atPath: current.path) ? current.resolvingSymlinksInPath() : root.appending(path: "QueryCraft MCP.app")
    }
    var executableURL: URL {
        FileManager.default.fileExists(atPath: root.appending(path: "Current").path)
            ? root.appending(path: "bin/querycraft-mcp") : appURL.appending(path: "Contents/MacOS/querycraft-mcp")
    }
    init(root: URL = QueryCraftStorageLocation.applicationSupportDirectory.appending(path: "MCP"),
         localPackage: URL? = nil, catalog: MCPComponentCatalog? = nil, host: MCPComponentHost = .current) {
        self.identity = MCPServerIdentity(directory: root.deletingLastPathComponent())
        self.root = root; self.localPackage = localPackage; self.catalog = catalog ?? MCPComponentCatalog(identity: self.identity); self.host = host
    }
    func installedVersion() async throws -> String? {
        let binary = appURL.appending(path: "Contents/MacOS/querycraft-mcp")
        guard FileManager.default.fileExists(atPath: binary.path) else { return nil }
        if FileManager.default.fileExists(atPath: root.appending(path: "Current").path),
           !appURL.path.hasPrefix(root.appending(path: "Versions").resolvingSymlinksInPath().path + "/") {
            throw MCPFailure("Active MCP version is outside its installation directory.")
        }
        try verify(appURL)
        return try await MCPProcess.run(binary, arguments: ["--version"])
    }
    func availableRelease() async throws -> MCPComponentRelease { try await catalog.latest(.mcp, host: host) }
    func availableVersion() async throws -> String? {
        if let localPackage { return Bundle(url: localPackage)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        return try await availableRelease().version
    }
    func install(onProgress: @escaping @Sendable (MCPComponentInstallationProgress) async -> Void = { _ in }) async throws {
        guard !installing else { throw MCPFailure("MCP installation is already running.") }
        installing = true; defer { installing = false }
        await onProgress(.init(phase: .checking))
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try MCPComponentLock(directory: root); defer { withExtendedLifetime(lock) {} }
        let staged = root.appending(path: ".install-" + UUID().uuidString)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staged) }
        let app: URL
        let identity: String
        let release: MCPComponentRelease?
        if let localPackage {
            // Dependency injection for signed fixtures; never a bundled-app fallback.
            await onProgress(.init(phase: .installing))
            app = staged.appending(path: "QueryCraft MCP.app")
            try fm.copyItem(at: localPackage, to: app)
            identity = "local-" + UUID().uuidString
            release = nil
        } else {
            let selected = try await availableRelease()
            try selected.validate(host: host, mcpVersion: nil)
            if let data = try? Data(contentsOf: appURL.deletingLastPathComponent().appending(path: "release.json")),
               let installed = try? JSONDecoder().decode(MCPComponentRelease.self, from: data), installed.newer(than: selected) {
                throw MCPFailure("Refusing an automatic MCP downgrade. Use explicit rollback instead.")
            }
            let archive = staged.appending(path: "download.zip")
            try await catalog.download(selected, to: archive, onProgress: onProgress)
            await onProgress(.init(phase: .extracting))
            let unpacked = staged.appending(path: "unpacked")
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await MCPComponentArchive.extract(archive, into: unpacked, root: "QueryCraftMCP")
            try selected.verifyPayload(at: unpacked.appending(path: "QueryCraftMCP/component.json"))
            app = unpacked.appending(path: "QueryCraftMCP/QueryCraft MCP.app")
            identity = selected.identity + (self.identity == .development ? "-dev" : "")
            release = selected
        }
        await onProgress(.init(phase: .verifying))
        try verify(app)
        if let release {
            guard Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
                  Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String == release.build else {
                throw MCPFailure("MCP bundle version does not match its signed catalog.")
            }
        }
        await onProgress(.init(phase: .selfTesting))
        _ = try await MCPProcess.run(app.appending(path: "Contents/MacOS/querycraft-mcp"), arguments: ["--self-test"])
        let launcher = app.appending(path: "Contents/Helpers/querycraft-mcp-launcher")
        try MCPComponentArchive.verifySignature(launcher)
        await onProgress(.init(phase: .installing))
        let versionRoot = root.appending(path: "Versions/" + identity)
        // Published versions are immutable: never rewrite resources of running sessions.
        if fm.fileExists(atPath: versionRoot.path) {
            guard let release, let data = try? Data(contentsOf: versionRoot.appending(path: "release.json")),
                  (try? JSONDecoder().decode(MCPComponentRelease.self, from: data)) == release else {
                throw MCPFailure("A different package already uses this MCP version and build.")
            }
            try verify(versionRoot.appending(path: self.identity.runtimeAppName))
        } else {
            try fm.createDirectory(at: versionRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do {
                try fm.moveItem(at: app, to: versionRoot.appending(path: self.identity.runtimeAppName))
                if let release { try JSONEncoder().encode(release).write(to: versionRoot.appending(path: "release.json"), options: .atomic) }
                _ = try await MCPProcess.run(versionRoot.appending(path: self.identity.runtimeAppName + "/Contents/MacOS/querycraft-mcp"), arguments: ["--self-test"])
            } catch { try? fm.removeItem(at: versionRoot); throw error }
        }
        let bin = root.appending(path: "bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let launcherStage = bin.appending(path: ".launcher-" + UUID().uuidString)
        defer { try? fm.removeItem(at: launcherStage) }
        try fm.copyItem(at: versionRoot.appending(path: self.identity.runtimeAppName + "/Contents/Helpers/querycraft-mcp-launcher"), to: launcherStage)
        try MCPComponentArchive.verifySignature(launcherStage)
        guard rename(launcherStage.path, bin.appending(path: "querycraft-mcp").path) == 0 else { throw MCPFailure("Cannot install the MCP launcher.") }
        try JSONEncoder().encode(host).write(to: root.appending(path: "host.json"), options: .atomic)
        if let old = try? fm.destinationOfSymbolicLink(atPath: root.appending(path: "Current").path),
           old != "Versions/" + identity + "/" + self.identity.runtimeAppName {
            try MCPComponentArchive.replaceLink(at: root.appending(path: "Previous"), with: old)
        }
        try MCPComponentArchive.replaceLink(at: root.appending(path: "Current"), with: "Versions/" + identity + "/" + self.identity.runtimeAppName)
        // Keep old versions and the legacy app until clients/sessions no longer use them.
    }
    func rollback() async throws {
        let lock = try MCPComponentLock(directory: root); defer { withExtendedLifetime(lock) {} }
        let previous = root.appending(path: "Previous").resolvingSymlinksInPath()
        guard previous.path.hasPrefix(root.appending(path: "Versions").resolvingSymlinksInPath().path + "/"),
              let data = try? Data(contentsOf: previous.deletingLastPathComponent().appending(path: "release.json")) else {
            throw MCPFailure("No previous MCP version is installed.")
        }
        let release = try JSONDecoder().decode(MCPComponentRelease.self, from: data)
        try release.validate(host: host, mcpVersion: nil)
        try verify(previous)
        _ = try await MCPProcess.run(previous.appending(path: "Contents/MacOS/querycraft-mcp"), arguments: ["--self-test"])
        let current = try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "Current").path)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "Previous").path)
        try MCPComponentArchive.replaceLink(at: root.appending(path: "Current"), with: target)
        try MCPComponentArchive.replaceLink(at: root.appending(path: "Previous"), with: current)
    }
    func uninstall() throws {
        guard !installing else { throw MCPFailure("Wait for MCP installation to finish.") }
        let lock = try MCPComponentLock(directory: root); defer { withExtendedLifetime(lock) {} }
        // Connections, authorization and history are siblings of this installation.
        for name in ["Current", "Previous", "bin", "Versions", "host.json", "QueryCraft MCP.app"] {
            let url = root.appending(path: name)
            if (try? fmAttributes(url)) != nil { try FileManager.default.removeItem(at: url) }
        }
    }
    private func fmAttributes(_ url: URL) throws -> [FileAttributeKey: Any] { try FileManager.default.attributesOfItem(atPath: url.path) }
    private func verify(_ url: URL) throws { try MCPComponentArchive.verifySignature(url, bundleIDs: Self.runtimeIDs) }
}

enum MCPProcess {
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 30,
                    environment: [String: String]? = nil, workingDirectory: URL? = nil) async throws -> String {
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let url = FileManager.default.temporaryDirectory.appending(path: "querycraft-process-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MCPFailure("Cannot create MCP process log.")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw MCPFailure("MCP process timed out.") }
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard bytes <= 1_048_576 else { throw MCPFailure("MCP process output exceeded its limit.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard process.terminationStatus == 0 else {
            if arguments.contains("--authorize-credentials"),
               let data = try? Data(contentsOf: url),
               let result = try? JSONDecoder().decode([String: String].self, from: data),
               let raw = result["credential_error"], let code = MCPFailureCode(rawValue: raw),
               [.credentialDenied, .credentialCancelled, .credentialUnavailable].contains(code) {
                throw MCPFailure(AppCopy.current.text(
                    code == .credentialCancelled ? "密码授权已取消；可再次点击授权。若密码已丢失，请在连接编辑器重新保存。" : "无法访问已保存的密码。请解锁钥匙串后重新授权；若密码已丢失，请在连接编辑器重新保存。",
                    code.recovery), code: code)
            }
            throw MCPFailure("MCP process failed (exit \(process.terminationStatus)).")
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

enum MCPClientConfiguration {
    static let clients = ["Claude Code", "Cursor", "CodeBuddy Code", "ZCode", "TRAE", "VS Code", "Windsurf", "Codex", "DeepSeek Harness", "OpenCode", "Pi", "Cherry Studio"]
    static func supportsHTTP(_ client: String) -> Bool {
        !["DeepSeek Harness", "Pi"].contains(client)
    }
    static func guidance(_ client: String) -> String {
        let zh: String
        switch client {
        case "Claude Code": zh = "一键添加写入用户配置；也可复制到项目 .mcp.json。添加后重新连接 MCP。"
        case "Cursor": zh = "合并到 ~/.cursor/mcp.json 或项目 .cursor/mcp.json。"
        case "VS Code": zh = "一键添加写入默认用户配置；自定义 Profile 可复制到其 MCP 配置。"
        case "Codex": zh = "合并到 ~/.codex/config.toml。"
        case "OpenCode": zh = "合并到 opencode.json 的 mcp 配置。"
        case "DeepSeek Harness": zh = "将 YAML 加入 Harness 配置；需启用 @deepseek-ai/dsh-mcp-client。当前提供 stdio 模板。"
        case "Pi": zh = "Pi 需要支持 MCP 的扩展/桥接器；此处为桥接器的 mcpServers 配置，并非 Pi 核心配置。当前提供 stdio 模板。"
        case "Cherry Studio": zh = "在 MCP 服务器设置中导入 JSON 配置。"
        default: zh = "在客户端 MCP 设置中合并此配置，然后重新连接。"
        }
        let en: String
        switch client {
        case "Claude Code": en = "Add to client writes user configuration. You can also copy into a project's .mcp.json. Reconnect MCP afterwards."
        case "VS Code": en = "Add to client writes the default user profile. Copy configuration for a custom profile."
        case "Codex", "Cursor", "OpenCode": en = "Add to client updates user configuration. Reconnect MCP or restart the client afterwards."
        case "Pi": en = "Pi requires an MCP bridge. This stdio template is for the bridge, not Pi core."
        case "DeepSeek Harness": en = "Add this YAML with @deepseek-ai/dsh-mcp-client enabled. This template uses stdio."
        default: en = "Merge this into your client's MCP configuration and reconnect."
        }
        return AppCopy.current.text(zh, en)
    }
    static func make(client: String, executable: String, dataDirectory: String, http: MCPHTTPSettings?) -> String {
        func quoted(_ s: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: (try? encoder.encode(s)) ?? Data(), as: UTF8.self)
        }
        let identity = MCPServerIdentity(directory: URL(fileURLWithPath: dataDirectory, isDirectory: true))
        let name = identity.clientName
        let args = ["--stdio", "--data-dir", dataDirectory]
        let array = "[" + args.map(quoted).joined(separator: ", ") + "]"
        if http != nil && !supportsHTTP(client) {
            return AppCopy.current.text("此客户端当前提供本地 stdio 配置，请切换至「本地 stdio」。", "Select Local stdio for this client's supported template.")
        }
        if client == "Codex" {
            if let http { return "[mcp_servers.\(name)]\nurl = \(quoted(http.endpoint))\n\n[mcp_servers.\(name).http_headers]\nAuthorization = \(quoted("Bearer " + http.token))" }
            return "[mcp_servers.\(name)]\ncommand = \(quoted(executable))\nargs = \(array)"
        }
        if client == "DeepSeek Harness" {
            return "- insert:\n    - id: mcp-\(name)\n      name: '@deepseek-ai/dsh-mcp-client'\n      config:\n        serverName: \(name)\n        transport: stdio\n        command: \(quoted(executable))\n        args: \(array)"
        }
        var config: [String: Any]
        if let http { config = ["url": http.endpoint, "headers": ["Authorization": "Bearer " + http.token], "type": "http"] }
        else { config = ["command": executable, "args": args] }
        let root: String
        if client == "VS Code" { root = "servers"; if http == nil { config["type"] = "stdio" } }
        else if client == "OpenCode" {
            root = "mcp"
            if http == nil { config = ["type": "local", "command": [executable] + args] }
            else { config["type"] = "remote" }
        } else {
            root = "mcpServers"
            if client == "Cherry Studio" {
                config["name"] = identity.displayName; config["description"] = ""; config["isActive"] = true
                config["baseUrl"] = http?.endpoint ?? ""
                config["type"] = http == nil ? "stdio" : "streamableHttp"
                config.removeValue(forKey: "url")
                if http == nil { config["env"] = [String: String]() }
            }
        }
        let data = try? JSONSerialization.data(withJSONObject: [root: [name: config]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}
