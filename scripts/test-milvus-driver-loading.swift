import Foundation
import QueryCraftFeature

@main
struct MilvusDriverLoadingCheck {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else { fatalError("Expected driver bundle path") }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else { fatalError("Missing driver entry") }
        try await entry.init().activate()
        let configuration = DatabaseConnectionConfiguration(databaseType: .milvus, host: "127.0.0.1", port: 19530,
            authentication: .none, database: "default", tlsMode: .disabled)
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: configuration)
        guard session.resolvedCapabilities == .milvus else { fatalError("Unexpected capabilities") }
        guard session is any WorkspaceRequestExecutingSession else { fatalError("Milvus REST execution interface is missing") }
        await session.close()
        print("PASS Milvus packaged driver load, activation and read-only session factory")
    }
}
