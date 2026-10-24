import Testing
#if os(iOS)
import QueryCraftMobileCore
@testable import QueryCraftMobileProof
#else
@testable import QueryCraftPostgreSQLDriver
#endif

struct PostgreSQLCapabilitiesTests {
    @Test func distinguishesPostgreSQL17DatabaseLocaleCatalog() {
        #expect(!PostgreSQLCapabilities(serverVersion: 160_000).hasDatabaseLocale)
        #expect(PostgreSQLCapabilities(serverVersion: 170_000).hasDatabaseLocale)
    }

    @Test func preservesOlderGeneratedAndIdentityCapabilityBoundaries() {
        #expect(!PostgreSQLCapabilities(serverVersion: 90_600).hasIdentityColumns)
        #expect(PostgreSQLCapabilities(serverVersion: 100_000).hasIdentityColumns)
        #expect(!PostgreSQLCapabilities(serverVersion: 110_000).hasGeneratedColumns)
        #expect(PostgreSQLCapabilities(serverVersion: 120_000).hasGeneratedColumns)
    }
}
