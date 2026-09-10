struct MySQLConnectionTester {
    func test(
        _ configuration: DatabaseConnectionConfiguration
    ) async throws {
        try await test(MySQLConnectionConfiguration(configuration))
    }

    func test(_ configuration: MySQLConnectionConfiguration) async throws {
        let client = MariaDBClient(
            configuration: configuration.transportConfiguration
        )
        do {
            try await client.connect()
            _ = try await client.query("SELECT 1")
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }
}
import QueryCraftFeature
import QueryCraftMariaDBTransport
