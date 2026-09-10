import QueryCraftFeature
import QueryCraftMariaDBTransport

struct DorisConnectionTester {
    func test(_ configuration: DatabaseConnectionConfiguration) async throws {
        let configuration = try DorisConnectionConfiguration(configuration)
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
