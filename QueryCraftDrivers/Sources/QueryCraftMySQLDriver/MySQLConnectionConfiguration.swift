struct MySQLConnectionConfiguration: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String?
    let tlsMode: ConnectionTLSMode

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .mysql,
              configuration.databaseProduct.databaseType == .mysql
        else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .mysql,
                actual: configuration.databaseType
            )
        }
        guard case .usernamePassword = configuration.authentication else {
            throw DatabaseDriverError.unsupportedAuthentication(
                databaseType: .mysql,
                method: configuration.authentication.method
            )
        }
        host = configuration.host
        port = configuration.port
        username = configuration.username
        password = configuration.password
        database = configuration.database
        tlsMode = configuration.tlsMode
    }

    init(
        host: String,
        port: Int,
        username: String,
        password: String?,
        database: String?,
        tlsMode: ConnectionTLSMode
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tlsMode = tlsMode
    }

    var transportConfiguration: MariaDBTransportConfiguration {
        MariaDBTransportConfiguration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tlsMode: tlsMode
        )
    }
}
import QueryCraftFeature
import QueryCraftMariaDBTransport
