import QueryCraftFeature
import Testing
@testable import QueryCraftRedisDriver

struct RedisConnectionConfigurationTests {
    @Test func parsesLogicalDatabaseNames() throws {
        let configuration = try RedisConnectionConfiguration(
            DatabaseConnectionConfiguration(
                databaseType: .redis,
                host: "localhost",
                port: 6_379,
                username: "",
                password: nil,
                database: "DB 12",
                tlsMode: .disabled
            )
        )

        #expect(configuration.databaseIndex == 12)
    }

    @Test func rejectsTLSUntilTheDriverSupportsIt() {
        #expect(throws: RedisWorkspaceError.unsupportedTLS) {
            _ = try RedisConnectionConfiguration(
                DatabaseConnectionConfiguration(
                    databaseType: .redis,
                    host: "localhost",
                    port: 6_379,
                    username: "",
                    password: nil,
                    database: "DB 0",
                    tlsMode: .required
                )
            )
        }
    }
}
