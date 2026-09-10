import Foundation
import Testing
import QueryCraftMariaDBTransport

@testable import QueryCraftFeature
@testable import QueryCraftMySQLDriver

struct MySQL56CompatibilityTests {
    @Test
    func listsDatabasesThroughMariaDBConnectorC() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["QUERYCRAFT_MYSQL56_PASSWORD"],
              !password.isEmpty
        else { return }

        let host = environment["QUERYCRAFT_MYSQL56_HOST"] ?? "127.0.0.1"
        let port = Int(environment["QUERYCRAFT_MYSQL56_PORT"] ?? "3356") ?? 3356
        let username = environment["QUERYCRAFT_MYSQL56_USER"] ?? "root"
        let database = environment["QUERYCRAFT_MYSQL56_DATABASE"]
            ?? "querycraft_driver_test"
        let configuration = MySQLConnectionConfiguration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tlsMode: .disabled
        )
        let client = MariaDBClient(
            configuration: configuration.transportConfiguration
        )

        do {
            try await client.connect()
            let version = try #require(await client.serverVersion())
            #expect(version.hasPrefix("5.6."))

            let result = try await client.query("SHOW DATABASES")
            #expect(result.rows.contains { row in
                row.first == database
            })
        } catch {
            await client.close()
            throw error
        }

        await client.close()
    }
}
