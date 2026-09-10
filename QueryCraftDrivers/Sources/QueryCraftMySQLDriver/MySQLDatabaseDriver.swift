import QueryCraftFeature

struct MySQLDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.mysql

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        MySQLWorkspaceSession(
            configuration: try MySQLConnectionConfiguration(configuration)
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
        try await MySQLConnectionTester().test(configuration)
    }
}
