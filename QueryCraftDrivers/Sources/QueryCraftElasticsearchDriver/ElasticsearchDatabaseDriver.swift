import QueryCraftFeature

struct ElasticsearchDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.elasticsearch

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        try ElasticsearchWorkspaceSession(
            configuration: ElasticsearchConnectionConfiguration(configuration)
        )
    }

    func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        let session = try ElasticsearchWorkspaceSession(
            configuration: ElasticsearchConnectionConfiguration(configuration)
        )
        do {
            try await session.connect()
            await session.close()
        } catch {
            await session.close()
            throw error
        }
    }
}
