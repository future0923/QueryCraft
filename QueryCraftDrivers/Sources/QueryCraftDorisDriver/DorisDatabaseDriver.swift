import QueryCraftFeature

struct DorisDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.doris

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        DorisWorkspaceSession(
            configuration: try DorisConnectionConfiguration(configuration)
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
        try await DorisConnectionTester().test(configuration)
    }
}
