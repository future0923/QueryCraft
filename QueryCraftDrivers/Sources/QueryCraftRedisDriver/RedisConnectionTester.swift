import QueryCraftFeature

struct RedisConnectionTester {
    func test(
        _ configuration: DatabaseConnectionConfiguration
    ) async throws {
        let resolved = try RedisConnectionConfiguration(configuration)
        let client = RedisClient(configuration: resolved)
        do {
            try await client.connect()
            guard await client.isConnected() else {
                throw RedisClientError(message: "Redis did not respond to PING.")
            }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }
}
