import QueryCraftFeature
import QueryCraftMariaDBTransport
import Testing
@testable import QueryCraftDorisDriver

struct DorisDriverTests {
    @Test func acceptsBothDorisProducts() throws {
        let apacheDoris = try DorisConnectionConfiguration(
            configuration(product: .apacheDoris)
        )
        let selectDB = try DorisConnectionConfiguration(
            configuration(product: .selectDB)
        )

        #expect(apacheDoris.product == .apacheDoris)
        #expect(selectDB.product == .selectDB)
        #expect(apacheDoris.transportConfiguration.port == 9_030)
    }

    @Test func rejectsMySQLConfiguration() {
        #expect(throws: DatabaseDriverError.configurationTypeMismatch(
            expected: .doris,
            actual: .mysql
        )) {
            try DorisConnectionConfiguration(
                DatabaseConnectionConfiguration(
                    host: "localhost",
                    port: 3_306,
                    username: "root",
                    password: nil,
                    database: nil,
                    tlsMode: .disabled
                )
            )
        }
    }

    @Test func declaresReadOnlyWorkspaceCapabilities() throws {
        let session = DorisWorkspaceSession(
            configuration: try DorisConnectionConfiguration(
                configuration(product: .apacheDoris)
            )
        )

        #expect(session.capabilities == .dorisReadOnly)
    }

    private func configuration(
        product: DatabaseProduct
    ) -> DatabaseConnectionConfiguration {
        DatabaseConnectionConfiguration(
            databaseType: .doris,
            databaseProduct: product,
            host: "localhost",
            port: 9_030,
            username: "root",
            password: nil,
            database: nil,
            tlsMode: .disabled
        )
    }
}
