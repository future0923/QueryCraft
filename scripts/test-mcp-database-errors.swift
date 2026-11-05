import Foundation
@testable import QueryCraftFeature

/// Loads the packaged plugin and tests the same connect-before-query path used
/// by MCP. The Python wrapper supplies loopback protocol fixtures only.
@main struct MCPDatabaseErrorCheck {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let type = DatabaseType(rawValue: args[2]),
              let port = Int(args[3]) else { fatalError("Invalid fixture arguments") }
        let installer = DatabaseDriverPackageInstaller(
            driversDirectory: URL(fileURLWithPath: args[1]).deletingLastPathComponent(),
            compatibilityValidator: .init(appVersion: "0.1.14"), maintainsInstalledDrivers: false)
        for driver in await installer.loadInstalledDrivers() { await DatabaseDriverRegistry.shared.register(driver) }
        guard await DatabaseDriverRegistry.shared.isInstalled(type) else { fatalError("Driver did not activate") }
        if args[4] == "load_only" {
            print("PASS " + type.rawValue + " packaged plugin activated")
            return
        }
        let directory = URL(fileURLWithPath: args[5], isDirectory: true)
        let runtime = MCPRuntime(directory: directory)
        let profile = ConnectionProfile(id: UUID(), name: "protocol fixture", groupID: nil, databaseType: type,
            host: "127.0.0.1", port: port, username: "fixture", defaultDatabase: type == .redis ? "0" : "missing_fixture",
            tlsMode: .disabled, storesCredential: false, createdAt: Date())
        try await runtime.repository.insert(profile)
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.queryTimeoutSeconds = 3
        try MCPPolicyStore(directory: directory).save(policy)
        let tool = [.mysql, .doris, .postgresql].contains(type) ? "querycraft_execute_query" : "querycraft_list_databases"
        var arguments: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString)]
        if tool == "querycraft_execute_query" { arguments["sql"] = "SELECT 1 AS connection_ok" }
        do {
            _ = try await runtime.call(tool, arguments: arguments)
            fatalError("Expected protocol fixture failure")
        } catch {
            let failure = MCPFailure.normalized(error)
            guard failure.code.rawValue == args[4], failure.details?.objectValue?["phase"] == "connect" else {
                fatalError("Unexpected safe diagnostic: \(failure.value)")
            }
            if [.mysql, .doris].contains(type) {
                guard failure.details?.objectValue?["native_code"] == 1049 else { fatalError("Native error code was lost") }
            }
            let json = String(decoding: try JSONEncoder().encode(failure.value), as: UTF8.self)
            guard !json.contains("fixture-secret") else { fatalError("Native message leaked") }
            print("PASS " + type.rawValue + " packaged plugin → protocol error → MCP " + failure.code.rawValue)
        }
        await runtime.shutdown()
    }
}
