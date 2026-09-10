import QueryCraftFeature
import QueryCraftMariaDBTransport

struct DorisConnectionConfiguration: Equatable, Sendable {
    let product: DatabaseProduct
    let transportConfiguration: MariaDBTransportConfiguration

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .doris,
              configuration.databaseProduct.databaseType == .doris
        else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .doris,
                actual: configuration.databaseType
            )
        }
        guard case .usernamePassword = configuration.authentication else {
            throw DatabaseDriverError.unsupportedAuthentication(
                databaseType: .doris,
                method: configuration.authentication.method
            )
        }
        product = configuration.databaseProduct
        transportConfiguration = MariaDBTransportConfiguration(
            host: configuration.host,
            port: configuration.port,
            username: configuration.username,
            password: configuration.password,
            database: configuration.database,
            tlsMode: configuration.tlsMode
        )
    }
}
