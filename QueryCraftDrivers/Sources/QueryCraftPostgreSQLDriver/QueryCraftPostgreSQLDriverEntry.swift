import Foundation
import QueryCraftFeature

@MainActor
@objc(QueryCraftPostgreSQLDriverEntry)
public final class QueryCraftPostgreSQLDriverEntry: NSObject,
    QueryCraftDriverBundleEntry
{
    public required override init() {}

    public func activate() async throws {
        await DatabaseDriverRegistry.shared.register(PostgreSQLDatabaseDriver())
    }
}

struct PostgreSQLDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.postgresql

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        PostgreSQLWorkspaceSession(
            configuration: try PostgreSQLConnectionConfiguration(configuration)
        )
    }

    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> (any WorkspaceSession)? {
        try await makeSession(configuration: configuration)
    }

    func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        try await PostgreSQLConnectionTester().test(configuration)
    }
}
