import QueryCraftFeature

struct PostgreSQLConnectionConfiguration: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String
    let tlsMode: ConnectionTLSMode

    init(
        host: String,
        port: Int,
        username: String,
        password: String?,
        database: String,
        tlsMode: ConnectionTLSMode
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tlsMode = tlsMode
    }

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .postgresql,
              configuration.databaseProduct.databaseType == .postgresql
        else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .postgresql,
                actual: configuration.databaseType
            )
        }
        guard case .usernamePassword = configuration.authentication else {
            throw DatabaseDriverError.unsupportedAuthentication(
                databaseType: .postgresql,
                method: configuration.authentication.method
            )
        }
        host = configuration.host
        port = configuration.port
        username = configuration.username
        password = configuration.password
        database = configuration.database ?? "postgres"
        tlsMode = configuration.tlsMode
    }
}
