import Foundation
import Security
import MCP

/// Small C launcher links the same dynamic framework used by external drivers.
@_cdecl("QueryCraftMCPRun")
public func queryCraftMCPRun(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    let arguments = (1..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
    Task {
        do { try await QueryCraftMCPApplication.run(arguments: arguments); exit(0) }
        catch {
            if arguments.contains("--authorize-credentials") {
                let failure = MCPFailure.normalized(error)
                // Only a typed code crosses the process boundary; no raw Keychain detail.
                if let data = try? JSONEncoder().encode(["credential_error": failure.code.rawValue]) {
                    FileHandle.standardOutput.write(data)
                }
            }
            FileHandle.standardError.write(Data("QueryCraft MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

public enum QueryCraftMCPApplication {
    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "QCMCPVersion") as? String ?? "0.1.0" }

    public static func run(arguments: [String]) async throws {
        if arguments == ["--self-test"] {
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let parser = try SQLStructuralParser()
            _ = try await parser.parse(.init(revision: .init(1), text: "SELECT 1"))
            let runtime = MCPRuntime(directory: temporary)
            let server = await makeServer(runtime: runtime)
            let pair = await InMemoryTransport.createConnectedPair()
            try await server.start(transport: MCPInitializationTransport(pair.server))
            let client = Client(name: "QueryCraft Self Check", version: version)
            _ = try await client.connect(transport: pair.client)
            _ = try await client.listTools()
            await client.disconnect(); await server.stop(); await runtime.shutdown()
            print("MCP handshake OK")
            return
        }
        if arguments == ["--credential-protocol"] { print("2"); return }
        if arguments == ["--version"] { print(version); return }
        if arguments == ["--help"] {
            print("querycraft-mcp [--stdio | --http] [--data-dir PATH]\nComponents: --check-updates | --update | --rollback | --update-skill --skill-target shared|codex|claude.\nSettings and credentials are managed in QueryCraft → Settings → MCP.")
            return
        }
        var directory = QueryCraftStorageLocation.applicationSupportDirectory
        var checkDrivers = false
        var http = false
        var authorizeCredentials = false
        var componentAction: String?
        var skillDestination: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--check-updates", "--update", "--rollback", "--update-skill": componentAction = arguments[index]
            case "--skill-destination":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw MCPFailure("--skill-destination requires an absolute directory path.") }
                skillDestination = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--skill-target":
                index += 1
                guard index < arguments.count, let target = MCPSkillTarget(rawValue: arguments[index]) else { throw MCPFailure("--skill-target requires shared, codex or claude.") }
                skillDestination = target.directory
            case "--check-drivers": checkDrivers = true
            case "--authorize-credentials": authorizeCredentials = true
            case "--stdio": break
            case "--http": http = true
            case "--data-dir":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw MCPFailure("--data-dir requires an absolute directory path.") }
                directory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default: throw MCPFailure("Unknown argument: \(arguments[index])")
            }
            index += 1
        }
        if let componentAction {
            let componentRoot = directory.appending(path: "MCP")
            let host = (try? JSONDecoder().decode(MCPComponentHost.self, from: Data(contentsOf: componentRoot.appending(path: "host.json")))) ?? .current
            let catalog = MCPComponentCatalog()
            let installation = MCPInstallation(root: componentRoot, catalog: catalog, host: host)
            let service = MCPServiceManager(directory: directory)
            let wasRunningHTTP = await service.isRunning()
            let restartHTTP = ["--update", "--rollback"].contains(componentAction) && wasRunningHTTP
            let httpSettings = restartHTTP ? try MCPPolicyStore(directory: directory).load().http : nil
            if restartHTTP { try await service.stop() }
            do {
            switch componentAction {
            case "--update": try await installation.install(); print("MCP updated. Reconnect stdio clients to use the new runtime.")
            case "--rollback": try await installation.rollback(); print("Previous MCP version activated. Reconnect clients.")
            case "--update-skill":
                guard let skillDestination else { throw MCPFailure("Choose --skill-target shared, codex or claude.") }
                let skill = MCPSkillInstallation(catalog: catalog, host: host, cache: directory.appending(path: "SkillPackages"))
                try await skill.install(at: skillDestination, mcpVersion: try await installation.installedVersion())
                print("Skill updated. Reload your client's skills.")
            default:
                let runtime = try await installation.availableRelease()
                print("MCP available: \(runtime.version) (\(runtime.build))")
                if let current = try await installation.installedVersion() {
                    let skill = try await catalog.latest(.skill, host: host, mcpVersion: current)
                    print("Skill available: \(skill.version) (\(skill.build))")
                }
            }
            }
            catch {
                if let httpSettings { try? await service.start(executable: await installation.executableURL.path, settings: httpSettings) }
                throw error
            }
            if let httpSettings { try await service.start(executable: await installation.executableURL.path, settings: httpSettings) }
            return
        }
        SecKeychainSetUserInteractionAllowed(false)
        if authorizeCredentials {
            let policy = try MCPPolicyStore(directory: directory).load()
            let repository = SQLiteConnectionProfileRepository(databaseURL: directory.appending(path: "QueryCraft.sqlite"))
            let credentials = MCPCredentialStore(directory: directory)
            for profile in try await repository.fetchAll() where policy.permits(profile) && profile.storesCredential {
                do {
                    guard try await credentials.password(for: profile.id) != nil else {
                        throw MCPFailure("Saved credential is missing. Restore it in the QueryCraft connection editor.", code: .credentialUnavailable)
                    }
                } catch { throw MCPFailure.normalized(error) }
            }
            print("Credential authorization complete")
            return
        }
        // Driver discovery must never delete another host's installed driver on a compatibility failure.
        let installer = DatabaseDriverPackageInstaller(driversDirectory: DatabaseDriverPackageInstaller.installedDriversDirectory(in: directory),
            compatibilityValidator: .init(appVersion: Bundle.main.object(forInfoDictionaryKey: "QCAppVersion") as? String ?? "0.1.9"),
            maintainsInstalledDrivers: false)
        for driver in await installer.loadInstalledDrivers() { await DatabaseDriverRegistry.shared.register(driver) }
        if checkDrivers {
            let types = await DatabaseDriverRegistry.shared.installedDatabaseTypes().map(\.rawValue).sorted()
            print(String(decoding: try JSONEncoder().encode(types), as: UTF8.self))
            return
        }
        if http {
            try await MCPHTTPListener.run(directory: directory)
        } else {
            let runtime = MCPRuntime(directory: directory)
            let server = await makeServer(runtime: runtime)
            try await server.start(transport: MCPInitializationTransport(StdioTransport()))
            await server.waitUntilCompleted()
            await runtime.shutdown()
        }
    }

    static func makeServer(runtime: MCPRuntime) async -> Server {
        await runtime.startMaintenance()
        let server = Server(name: "QueryCraft", version: version, instructions: MCPToolCatalog.guidedInstructions,
            capabilities: .init(resources: .init(), tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: try await runtime.tools()) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let value = try await runtime.call(params.name, arguments: params.arguments ?? [:])
                let data = try JSONEncoder().encode(value)
                let maximumBytes = (try? runtime.store.load().maximumResultBytes) ?? 4 * 1024 * 1024
                guard data.count <= maximumBytes else { throw MCPFailure("Result exceeds the configured limit. Narrow the request.") }
                return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: false)
            } catch {
                let failure = MCPFailure.normalized(error)
                return .init(content: [.text(text: "[\(failure.code.rawValue)] \(failure.message)\n\(failure.code.recovery)", annotations: nil, _meta: nil)],
                             structuredContent: Optional.some(failure.value), isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            let tools = try await runtime.tools()
            return .init(resources: tools.contains(where: { $0.name == "querycraft_list_connections" })
                ? [.init(name: "connections", uri: "querycraft://connections", mimeType: "application/json")] : [])
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            let policy = try runtime.store.load()
            let templates: [(String, String, String)] = [
                ("list_databases", "querycraft://connections/{connection_id}/databases", "databases"),
                ("list_tables", "querycraft://connections/{connection_id}/tables{?database,schema,refresh}", "tables"),
                ("describe_table", "querycraft://connections/{connection_id}/table-schema{?database,schema,table,refresh}", "table-schema")
            ]
            return .init(templates: templates.filter { policy.enabled && !policy.disabledTools.contains($0.0) }.map {
                .init(uriTemplate: $0.1, name: $0.2, mimeType: "application/json")
            })
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard let url = URLComponents(string: params.uri), url.scheme == "querycraft", url.host == "connections" else {
                throw MCPError.invalidParams("Unknown resource URI")
            }
            let segments = url.path.split(separator: "/").map(String.init)
            var args: [String: Value] = [:]
            for item in url.queryItems ?? [] {
                guard ["database", "schema", "table", "refresh"].contains(item.name), args[item.name] == nil else { throw MCPError.invalidParams("Invalid resource arguments") }
                if item.name == "refresh" {
                    guard let value = item.value, ["true", "false"].contains(value) else { throw MCPError.invalidParams("refresh must be true or false") }
                    args[item.name] = .bool(value == "true")
                } else { args[item.name] = item.value.map(Value.string) }
            }
            let tool: String
            if segments.isEmpty { tool = "list_connections" }
            else {
                guard segments.count == 2, UUID(uuidString: segments[0]) != nil else { throw MCPError.invalidParams("Invalid connection resource") }
                args["connection_id"] = .string(segments[0])
                switch segments[1] {
                case "databases": tool = "list_databases"
                case "tables": tool = "list_tables"
                case "table-schema": tool = "describe_table"
                default: throw MCPError.invalidParams("Unknown resource")
                }
            }
            let result = try await runtime.call("querycraft_" + tool, arguments: args)
            let data = try JSONEncoder().encode(result)
            guard data.count <= (try runtime.store.load().maximumResultBytes) else { throw MCPError.invalidParams("Resource exceeds result limit") }
            return .init(contents: [.text(String(decoding: data, as: UTF8.self), uri: params.uri, mimeType: "application/json")])
        }
        return server
    }
}
