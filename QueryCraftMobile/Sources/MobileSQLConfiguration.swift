import QueryCraftMobileCore
import QueryCraftMobileTransport

/// Connection and query context are independent of a driver's wire protocol.
struct MobileSQLConfiguration: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String?
    let tlsMode: ConnectionTLSMode
    var driver: MobileDriver = .mysql
    var schemaName: String? = nil

    func selecting(database: String?, schema: String? = nil) -> Self {
        .init(host: host, port: port, username: username, password: password, database: database,
            tlsMode: tlsMode, driver: driver, schemaName: schema)
    }
    var mariaDB: MariaDBTransportConfiguration {
        .init(host: host, port: port, username: username, password: password, database: database, tlsMode: tlsMode)
    }
    var postgreSQL: PostgreSQLConnectionConfiguration {
        .init(host: host, port: port, username: username, password: password, database: database ?? "postgres", tlsMode: tlsMode, connectTimeout: 10)
    }
}

extension MariaDBConnection {
    convenience init(configuration: MobileSQLConfiguration) { self.init(configuration: configuration.mariaDB) }
    func mobilePreview(_ sql: String, maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview {
        .init(try await queryPreview(sql, maximumRows: maximumRows, maximumBytes: maximumBytes))
    }
}
