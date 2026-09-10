import QueryCraftFeature

struct PostgreSQLConnectionTester {
    func test(
        _ configuration: DatabaseConnectionConfiguration
    ) async throws {
        try await test(PostgreSQLConnectionConfiguration(configuration))
    }

    func test(_ configuration: PostgreSQLConnectionConfiguration) async throws {
        let client = LibPQClient(configuration: configuration)
        do {
            try await client.connect()
            let result = try await client.query("SELECT 1")
            guard result.rows.count == 1 else {
                throw WorkspaceSessionError.queryUnavailable
            }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }
}
