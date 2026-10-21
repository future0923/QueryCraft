import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPClientRegistrationTests {
    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func configuration(_ client: String, http: Bool = false) -> String {
        MCPClientConfiguration.make(client: client, executable: "/Applications/QueryCraft MCP.app/Contents/MacOS/querycraft-mcp",
                                    dataDirectory: "/tmp/QueryCraft fixture", http: http ? MCPHTTPSettings() : nil)
    }
    private func object(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    @Test(arguments: ["Claude Code", "Cursor", "VS Code", "OpenCode"])
    func addUpdateRemovePreservesOtherConfiguration(_ client: String) async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let registrar = MCPClientRegistration(home: home, environment: [:])
        let config = configuration(client)
        let inspection = try await registrar.inspect(client: client, configuration: config)
        #expect(inspection.state == .absent)
        let root = client == "OpenCode" ? "mcp" : client == "VS Code" ? "servers" : "mcpServers"
        let original = try JSONSerialization.data(withJSONObject: ["preferences": ["theme": "dark"], root: ["other": ["command": "fixture"]]])
        try FileManager.default.createDirectory(at: inspection.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: inspection.file)
        let backup = try #require(try await registrar.change(client: client, configuration: config, adding: true))
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await registrar.inspect(client: client, configuration: config).state == .registered)
        #expect(try await registrar.change(client: client, configuration: config, adding: true) == nil)
        let http = configuration(client, http: true)
        _ = try await registrar.change(client: client, configuration: http, adding: true)
        let updated = try object(inspection.file)
        #expect((updated["preferences"] as? [String: String])?["theme"] == "dark")
        #expect(((updated[root] as? [String: Any])?["other"] as? [String: String])?["command"] == "fixture")
        // Other servers may be edited between our operations.
        var external = updated; external["anotherSetting"] = true
        try JSONSerialization.data(withJSONObject: external).write(to: inspection.file)
        _ = try await registrar.change(client: client, configuration: http, adding: false)
        let removed = try object(inspection.file)
        #expect(removed["anotherSetting"] as? Bool == true)
        #expect((removed[root] as? [String: Any])?["querycraft"] == nil)
        #expect(try await registrar.change(client: client, configuration: http, adding: false) == nil)
    }

    @Test func protectsUnmanagedAndEditedEntries() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let registrar = MCPClientRegistration(home: home, environment: [:])
        let config = configuration("Cursor")
        let file = try await registrar.inspect(client: "Cursor", configuration: config).file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conflict = Data(#"{"mcpServers":{"querycraft":{"command":"someone-else"}}}"#.utf8)
        try conflict.write(to: file)
        #expect(try await registrar.inspect(client: "Cursor", configuration: config).state == .conflict)
        for adding in [true, false] {
            await #expect(throws: MCPFailure.self) { try await registrar.change(client: "Cursor", configuration: config, adding: adding) }
            #expect(try Data(contentsOf: file) == conflict)
        }
        try FileManager.default.removeItem(at: file)
        _ = try await registrar.change(client: "Cursor", configuration: config, adding: true)
        try conflict.write(to: file)
        await #expect(throws: MCPFailure.self) { try await registrar.change(client: "Cursor", configuration: config, adding: false) }
        #expect(try Data(contentsOf: file) == conflict)
    }

    @Test func adoptsExactCopiedEntryAndPreservesMalformedOrLinkedFiles() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let registrar = MCPClientRegistration(home: home, environment: [:])
        let config = configuration("Claude Code")
        let file = home.appending(path: ".claude.json")
        try Data(config.utf8).write(to: file)
        _ = try await registrar.change(client: "Claude Code", configuration: config, adding: false)
        #expect((try object(file)["mcpServers"] as? [String: Any])?.isEmpty == true)
        let malformed = Data("{broken".utf8)
        try malformed.write(to: file)
        await #expect(throws: MCPFailure.self) { try await registrar.change(client: "Claude Code", configuration: config, adding: true) }
        #expect(try Data(contentsOf: file) == malformed)
        try FileManager.default.removeItem(at: file)
        let outside = home.appending(path: "outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await #expect(throws: MCPFailure.self) { try await registrar.change(client: "Claude Code", configuration: config, adding: true) }
        #expect(try Data(contentsOf: outside) == Data("{}".utf8))
    }

    @Test func honorsCustomLocationsWithoutTouchingDefaultFiles() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appending(path: "custom")
        let registrar = MCPClientRegistration(home: home, environment: ["XDG_CONFIG_HOME": custom.path])
        let config = configuration("OpenCode")
        _ = try await registrar.change(client: "OpenCode", configuration: config, adding: true)
        #expect(FileManager.default.fileExists(atPath: custom.appending(path: "opencode/opencode.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".config").path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")))
    func codexNativeEditorPreservesModelProxyCommentsAndOtherMCP() async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appending(path: "custom-codex")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let file = custom.appending(path: "config.toml")
        let original = """
        # Keep my preferences
        model = "fixture-model"
        [features]
        respect_system_proxy = true # Keep the proxy fix
        [mcp_servers.other]
        command = "fixture"
        args = ["hello"]
        """
        try Data(original.utf8).write(to: file)
        let registrar = MCPClientRegistration(home: home, environment: ["CODEX_HOME": custom.path])
        let config = configuration("Codex")
        _ = try await registrar.change(client: "Codex", configuration: config, adding: true)
        #expect(try await registrar.inspect(client: "Codex", configuration: config).state == .registered)
        #expect(try await registrar.change(client: "Codex", configuration: config, adding: true) == nil)
        let http = configuration("Codex", http: true)
        _ = try await registrar.change(client: "Codex", configuration: http, adding: true)
        #expect(try await registrar.inspect(client: "Codex", configuration: http).state == .registered)
        _ = try await registrar.change(client: "Codex", configuration: http, adding: false)
        let restored = try String(contentsOf: file, encoding: .utf8)
        #expect(restored.contains("# Keep my preferences"))
        #expect(restored.contains("respect_system_proxy = true # Keep the proxy fix"))
        #expect(restored.contains("[mcp_servers.other]"))
        #expect(restored.contains("model = \"fixture-model\""))
        #expect(!restored.contains("mcp_servers.querycraft"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".codex").path))
    }
    @Test(arguments: ["Claude Code", "Cursor", "VS Code", "OpenCode", "Codex"])
    func developmentNameMigratesOwnedLegacyAndCoexistsWithProduction(_ client: String) async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let production = MCPClientRegistration(home: home, environment: [:])
        let development = MCPClientRegistration(home: home, environment: [:], identity: .development)
        func config(_ directory: String, http: Bool = false) -> String {
            MCPClientConfiguration.make(client: client, executable: "/tmp/" + directory + "/MCP/bin/querycraft-mcp",
                dataDirectory: "/tmp/" + directory, http: http ? MCPHTTPSettings() : nil)
        }
        let dev = config("QueryCraftDev")
        let legacy = dev.replacingOccurrences(of: "querycraft-dev", with: "querycraft")
        _ = try await production.change(client: client, configuration: legacy, adding: true)
        _ = try await development.change(client: client, configuration: dev, adding: true)
        #expect(try await development.inspect(client: client, configuration: dev).state == .registered)
        #expect(try await production.inspect(client: client, configuration: config("QueryCraft")).state == .absent)
        _ = try await production.change(client: client, configuration: config("QueryCraft"), adding: true)
        _ = try await development.change(client: client, configuration: config("QueryCraftDev", http: true), adding: true)
        #expect(try await production.inspect(client: client, configuration: config("QueryCraft")).state == .registered)
        _ = try await development.change(client: client, configuration: dev, adding: false)
        #expect(try await production.inspect(client: client, configuration: config("QueryCraft")).state == .registered)
        #expect(try await development.inspect(client: client, configuration: dev).state == .absent)
    }

    @Test(arguments: ["Claude Code", "Cursor", "VS Code", "OpenCode"])
    func developmentDoesNotAdoptProductionReceiptForModifiedEntry(_ client: String) async throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let production = MCPClientRegistration(home: home, environment: [:])
        let development = MCPClientRegistration(home: home, environment: [:], identity: .development)
        let prod = configuration(client)
        _ = try await production.change(client: client, configuration: prod, adding: true)
        let file = try await production.inspect(client: client, configuration: prod).file
        let root = client == "OpenCode" ? "mcp" : client == "VS Code" ? "servers" : "mcpServers"
        var document = try object(file), servers = try #require(try object(file)[root] as? [String: Any])
        servers["querycraft-dev"] = servers["querycraft"]
        document[root] = servers
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let dev = MCPClientConfiguration.make(client: client, executable: "/tmp/QueryCraftDev/MCP/bin/querycraft-mcp",
            dataDirectory: "/tmp/QueryCraftDev", http: nil)
        #expect(try await development.inspect(client: client, configuration: dev).state == .conflict)
        let before = try Data(contentsOf: file)
        await #expect(throws: MCPFailure.self) { try await development.change(client: client, configuration: dev, adding: true) }
        #expect(try Data(contentsOf: file) == before)
    }

}
