import Foundation
import Security

/// Shared desktop/driver host services for the separately linked MCP process.
/// JSON is the boundary: the desktop never imports the protocol SDK or NIO.
@_spi(MCP) public enum MCPHost {
    public static func prepare(arguments: [String]) async throws -> (directory: URL, http: Bool)? {
        if arguments == ["--credential-protocol"] { print("2"); return nil }
        if arguments == ["--version"] { print(Bundle.main.object(forInfoDictionaryKey: "QCMCPVersion") as? String ?? "0.1.0"); return nil }
        if arguments == ["--help"] {
            print("querycraft-mcp [--stdio | --http] [--data-dir PATH]\nComponents: --check-updates | --update | --rollback | --update-skill --skill-target shared|codex|claude.\nSSH: --install-ssh-plugin /absolute/QueryCraftSSH.bundle | --check-ssh-plugin\nSettings and credentials are managed in QueryCraft → Settings → MCP.")
            return nil
        }
        var directory = QueryCraftStorageLocation.applicationSupportDirectory
        var checkDrivers = false
        var http = false
        var authorizeCredentials = false
        var componentAction: String?
        var skillDestination: URL?
        var skillTarget: MCPSkillTarget?
        var sshSource: URL?
        var checkSSH = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--install-ssh-plugin":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw MCPFailure("--install-ssh-plugin requires an absolute bundle path.") }
                sshSource = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--check-ssh-plugin": checkSSH = true
            case "--check-updates", "--update", "--rollback", "--update-skill": componentAction = arguments[index]
            case "--skill-destination":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw MCPFailure("--skill-destination requires an absolute directory path.") }
                skillDestination = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--skill-target":
                index += 1
                guard index < arguments.count, let target = MCPSkillTarget(rawValue: arguments[index]) else { throw MCPFailure("--skill-target requires shared, codex or claude.") }
                skillTarget = target
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
        if let sshSource {
            let installed = try SSHPluginInstallation.install(source: sshSource, directory: directory)
            print("SSH plugin installed: \(installed.path)\nReconnect MCP clients to use it. SSH connections require explicit authorization.")
            return nil
        }
        if checkSSH {
            let plugin = try SSHPlugin(bundleURL: SSHPlugin.bundleURL(in: directory))
            withExtendedLifetime(plugin) { print("SSH plugin ABI 1 OK") }
            return nil
        }
        if skillDestination == nil, let skillTarget {
            skillDestination = skillTarget.directory(in: FileManager.default.homeDirectoryForCurrentUser, identity: MCPServerIdentity(directory: directory))
        }
        if let componentAction {
            let componentRoot = directory.appending(path: "MCP")
            let host = (try? JSONDecoder().decode(MCPComponentHost.self, from: Data(contentsOf: componentRoot.appending(path: "host.json")))) ?? .current
            let catalog = MCPComponentCatalog(identity: MCPServerIdentity(directory: directory))
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
            return nil
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
            return nil
        }
        // Driver discovery must never delete another host's installed driver on a compatibility failure.
        let installer = DatabaseDriverPackageInstaller(driversDirectory: DatabaseDriverPackageInstaller.installedDriversDirectory(in: directory),
            compatibilityValidator: .init(appVersion: Bundle.main.object(forInfoDictionaryKey: "QCAppVersion") as? String ?? "0.1.9"),
            maintainsInstalledDrivers: false)
        for driver in await installer.loadInstalledDrivers() { await DatabaseDriverRegistry.shared.register(driver) }
        if checkDrivers {
            let types = await DatabaseDriverRegistry.shared.installedDatabaseTypes().map(\.rawValue).sorted()
            print(String(decoding: try JSONEncoder().encode(types), as: UTF8.self))
            return nil
        }
        return (directory, http)
    }

    public static func selfTestParser() async throws {
        let parser = try SQLStructuralParser()
        _ = try await parser.parse(.init(revision: .init(1), text: "SELECT 1"))
    }

    public static var instructions: String { MCPToolCatalog.guidedInstructions }

    public static func failure(_ error: any Error) throws -> (text: String, json: Data, code: String) {
        let failure = MCPFailure.normalized(error)
        return ("[\(failure.code.rawValue)] \(failure.message)\n\(failure.code.recovery)",
                try JSONEncoder().encode(failure.value), failure.code.rawValue)
    }

    public static func httpConfiguration(directory: URL) throws -> Data {
        let policy = try MCPPolicyStore(directory: directory).load()
        try policy.authorize(tool: "http")
        try policy.http.validate()
        return try JSONEncoder().encode(policy.http)
    }
}

@_spi(MCP) public actor MCPHostRuntime {
    private let runtime: MCPRuntime
    public nonisolated let displayName: String
    public init(directory: URL) {
        runtime = MCPRuntime(directory: directory)
        displayName = MCPServerIdentity(directory: directory).displayName
    }
    public func startMaintenance() async { await runtime.startMaintenance() }
    public func shutdown() async { await runtime.shutdown() }
    public func tools() async throws -> Data { try JSONEncoder().encode(await runtime.tools()) }
    public func call(_ name: String, arguments: Data) async throws -> Data {
        let args = try JSONDecoder().decode([String: MCPJSONValue].self, from: arguments)
        return try JSONEncoder().encode(await runtime.call(name, arguments: args))
    }
    public nonisolated func maximumResultBytes() throws -> Int { try runtime.store.load().maximumResultBytes }
    public nonisolated func resourceTools() throws -> Set<String> {
        let policy = try runtime.store.load()
        return policy.enabled ? Set(["list_databases", "list_tables", "describe_table"]).subtracting(policy.disabledTools) : []
    }
}
