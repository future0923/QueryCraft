import QueryCraftFeature

struct RedisDatabaseDriver: DatabaseDriver {
    let databaseType = DatabaseType.redis

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        RedisDriverWorkspaceSession(
            configuration: try RedisConnectionConfiguration(configuration)
        )
    }

    func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        try await RedisConnectionTester().test(configuration)
    }
}
