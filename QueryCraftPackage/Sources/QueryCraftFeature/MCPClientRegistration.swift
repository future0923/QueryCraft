import CryptoKit
import Foundation

/// Edits only the named MCP entry. Codex's own TOML editor preserves unrelated settings/comments.
actor MCPClientRegistration {
    enum State: Sendable { case absent, registered, conflict }
    struct Inspection: Sendable {
        let file: URL
        let state: State
    }
    private struct Target {
        let file: URL
        let root: String
        var isCodex: Bool { root == "mcp_servers" }
    }
    private let home: URL
    private let environment: [String: String]
    private let receipts: URL
    private let codexExecutable: URL?
    private var changing = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         receipts: URL? = nil, codexExecutable: URL? = nil) {
        self.home = home; self.environment = environment
        self.receipts = receipts ?? home.appending(path: "Library/Application Support/QueryCraft/MCPClientRegistrations")
        self.codexExecutable = codexExecutable
    }

    static func supports(_ client: String) -> Bool {
        ["Codex", "Claude Code", "Cursor", "VS Code", "OpenCode"].contains(client)
    }

    func inspect(client: String, configuration: String) async throws -> Inspection {
        let target = try target(client)
        let original = try read(target.file)
        let entry = try await entry(in: original, target: target)
        let desired = try await desiredEntry(configuration, target: target)
        let state: State
        if let entry {
            let digest = try hash(entry)
            let desiredHash = try hash(desired), accepted = try acceptedHashes(target)
            state = (digest == desiredHash || accepted.contains(digest)) ? .registered : .conflict
        } else { state = .absent }
        return Inspection(file: target.file, state: state)
    }

    @discardableResult
    func change(client: String, configuration: String, adding: Bool) async throws -> URL? {
        guard !changing else { throw failure("另一个客户端配置操作正在进行。", "Another client configuration operation is running.") }
        changing = true; defer { changing = false }
        let target = try target(client)
        try checkPath(target.file)
        try FileManager.default.createDirectory(at: target.file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockFile = target.file.deletingLastPathComponent().appending(path: ".querycraft-mcp.lock")
        let descriptor = open(lockFile.path, O_CREAT | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MCPFailure("Cannot lock client configuration.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw failure("另一个 QueryCraft 正在更新此配置，请稍后重试。", "Another QueryCraft process is updating this configuration. Try again shortly.")
        }
        defer { flock(descriptor, LOCK_UN) }
        let original = try read(target.file)
        let existing = try await entry(in: original, target: target)
        let desired = try await desiredEntry(configuration, target: target)
        let desiredHash = try hash(desired)
        var accepted = try acceptedHashes(target)
        if let existing {
            let digest = try hash(existing)
            guard digest == desiredHash || accepted.contains(digest) else {
                throw failure("同名 QueryCraft 配置已被修改或由其他程序管理，已保留。请在客户端检查。", "The QueryCraft entry was modified or belongs to another configuration. It has been preserved; review it in your client.")
            }
            if adding && digest == desiredHash {
                // Adopt an exact manually copied entry so later transport updates remain possible.
                try privateWrite(try JSONEncoder().encode([desiredHash]), to: receipt(target))
                return nil
            }
            accepted.insert(digest)
        } else if !adding { return nil }

        let updated: Data
        if target.isCodex {
            updated = try await withCodex(original) { executable, stage, env in
                if existing != nil {
                    _ = try await MCPProcess.run(executable, arguments: ["mcp", "remove", "querycraft"], environment: env, workingDirectory: stage)
                }
                let file = stage.appending(path: "config.toml")
                if adding {
                    var data = try Data(contentsOf: file)
                    data.append(Data(("\n" + configuration + "\n").utf8))
                    try data.write(to: file, options: .atomic)
                }
                _ = try await MCPProcess.run(executable, arguments: ["mcp", "list", "--json"], environment: env, workingDirectory: stage)
                return try Data(contentsOf: file)
            }
        } else {
            var document = try jsonDocument(original)
            var servers = (document[target.root] as? [String: Any]) ?? [:]
            if adding { servers["querycraft"] = desired } else { servers.removeValue(forKey: "querycraft") }
            // Preserve an existing empty container and all unrelated document fields.
            document[target.root] = servers
            updated = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        }
        try Task.checkCancellation()
        guard try read(target.file) == original else {
            throw failure("客户端配置在操作期间发生变化，请重新检查后重试。", "The client configuration changed during this operation. Check again and retry.")
        }
        // Write the receipt first. A failed config write can leave only hashes for known generated entries,
        // never permission to overwrite an arbitrary entry. Retain the previous hash for crash recovery.
        if adding {
            accepted.insert(desiredHash)
            try privateWrite(try JSONEncoder().encode(accepted.sorted()), to: receipt(target))
        }
        let backup: URL?
        if let original {
            let file = target.file.deletingLastPathComponent().appending(path: target.file.lastPathComponent + ".querycraft-backup-" + UUID().uuidString)
            try privateWrite(original, to: file); backup = file
        } else { backup = nil }
        guard try read(target.file) == original else {
            throw failure("客户端配置已变化，未覆盖。", "The client configuration changed; it was not overwritten.")
        }
        try privateWrite(updated, to: target.file)
        if adding {
            try? privateWrite(try JSONEncoder().encode([desiredHash]), to: receipt(target))
        } else { try? FileManager.default.removeItem(at: receipt(target)) }
        return backup
    }

    private func target(_ client: String) throws -> Target {
        func location(_ key: String, _ fallback: String) throws -> URL {
            guard let value = environment[key], !value.isEmpty else {
                return fallback.hasPrefix("/") ? URL(fileURLWithPath: fallback) : home.appending(path: fallback)
            }
            guard value.hasPrefix("/") else { throw failure("客户端自定义配置路径必须是绝对路径。", "The custom client configuration path must be absolute.") }
            return URL(fileURLWithPath: value)
        }
        switch client {
        case "Codex": return Target(file: try location("CODEX_HOME", ".codex").appending(path: "config.toml"), root: "mcp_servers")
        case "Claude Code":
            let dir = try location("CLAUDE_CONFIG_DIR", ".claude")
            // Claude's default user file is beside .claude; a custom config directory contains it.
            let file = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } == nil
                ? home.appending(path: ".claude.json") : dir.appending(path: ".claude.json")
            return Target(file: file, root: "mcpServers")
        case "Cursor": return Target(file: home.appending(path: ".cursor/mcp.json"), root: "mcpServers")
        case "VS Code": return Target(file: home.appending(path: "Library/Application Support/Code/User/mcp.json"), root: "servers")
        case "OpenCode":
            let base = try location("XDG_CONFIG_HOME", ".config").appending(path: "opencode")
            let file = try location("OPENCODE_CONFIG", base.appending(path: "opencode.json").path)
            if environment["OPENCODE_CONFIG"] == nil,
               FileManager.default.fileExists(atPath: base.appending(path: "opencode.jsonc").path) {
                throw failure("检测到 OpenCode JSONC 配置，请使用复制配置合并以保留注释。", "OpenCode uses JSONC. Merge the copied configuration to preserve its comments.")
            }
            return Target(file: file, root: "mcp")
        default: throw failure("此客户端暂不支持自动配置，请使用复制配置。", "Use Copy configuration for this client; automatic configuration is not supported yet.")
        }
    }

    private func entry(in data: Data?, target: Target) async throws -> [String: Any]? {
        if target.isCodex {
            return try await withCodex(data) { executable, stage, env in
                let output = try await MCPProcess.run(executable, arguments: ["mcp", "list", "--json"], environment: env, workingDirectory: stage)
                guard let rows = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { throw MCPFailure("Invalid Codex configuration response.") }
                guard rows.contains(where: { $0["name"] as? String == "querycraft" }) else { return nil }
                let entry = try await MCPProcess.run(executable, arguments: ["mcp", "get", "querycraft", "--json"], environment: env, workingDirectory: stage)
                return try JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any]
            }
        }
        let document = try jsonDocument(data)
        guard let container = document[target.root] else { return nil }
        guard let servers = container as? [String: Any] else { throw invalidJSON() }
        guard let value = servers["querycraft"] else { return nil }
        guard let value = value as? [String: Any] else { throw invalidJSON() }
        return value
    }

    private func desiredEntry(_ configuration: String, target: Target) async throws -> [String: Any] {
        let data = Data(configuration.utf8)
        guard let entry = try await entry(in: data, target: target) else { throw invalidJSON() }
        return entry
    }

    private func jsonDocument(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalidJSON() }
            return object
        } catch { throw invalidJSON() }
    }
    private func invalidJSON() -> MCPFailure {
        failure("配置格式无法安全合并，已保留原文件。带注释的 JSON 请使用复制配置。", "The configuration cannot be safely merged. The original is preserved. Use Copy configuration for JSON with comments.")
    }
    private func hash(_ entry: [String: Any]) throws -> String {
        digest(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func receipt(_ target: Target) -> URL { receipts.appending(path: digest(Data(target.file.standardizedFileURL.path.utf8)) + ".json") }
    private func acceptedHashes(_ target: Target) throws -> Set<String> {
        guard let data = try read(receipt(target)) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    private func read(_ url: URL) throws -> Data? {
        try checkPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8_388_608 else {
            throw failure("配置文件不是普通文件或超过 8 MB，已保留。", "The configuration is not a regular file or exceeds 8 MB; it is preserved.")
        }
        return try Data(contentsOf: url)
    }
    private func checkPath(_ url: URL) throws {
        // Resolve standard macOS aliases (/var -> /private/var) before testing parent symlinks.
        var path = url.standardizedFileURL
        while path.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                if path.path != "/var" && path.path != "/tmp" {
                    throw failure("配置路径包含符号链接，未修改文件。", "The configuration path contains a symbolic link; no files were changed.")
                }
            }
            path.deleteLastPathComponent()
        }
    }
    private func privateWrite(_ data: Data, to url: URL) throws {
        try checkPath(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = url.deletingLastPathComponent().appending(path: ".querycraft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw MCPFailure("Cannot stage client configuration.") }
        guard rename(staged.path, url.path) == 0 else { throw MCPFailure("Cannot save client configuration.") }
    }
    private func withCodex<T>(_ original: Data?, _ operation: (URL, URL, [String: String]) async throws -> T) async throws -> T {
        let candidates = [codexExecutable?.path,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .compactMap { $0 } + (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw failure("未找到 Codex 命令行工具，请安装 Codex 后重新检查，或复制配置。", "Codex CLI was not found. Install Codex and check again, or copy the configuration.")
        }
        let stage = FileManager.default.temporaryDirectory.appending(path: "querycraft-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        try privateWrite(original ?? Data(), to: stage.appending(path: "config.toml"))
        var env = environment; env["CODEX_HOME"] = stage.path
        env["HOME"] = home.path
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return try await operation(URL(fileURLWithPath: path), stage, env)
    }
    private func failure(_ zh: String, _ en: String) -> MCPFailure { MCPFailure(AppCopy.current.text(zh, en)) }
}
