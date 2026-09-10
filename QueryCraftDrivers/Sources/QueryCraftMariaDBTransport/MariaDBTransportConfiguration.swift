import QueryCraftFeature

package struct MariaDBTransportConfiguration: Equatable, Sendable {
    package let host: String
    package let port: Int
    package let username: String
    package let password: String?
    package let database: String?
    package let tlsMode: ConnectionTLSMode

    package init(
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
}
