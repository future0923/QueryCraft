#if canImport(QueryCraftFeature)
import QueryCraftFeature
#elseif canImport(QueryCraftMobileCore)
import QueryCraftMobileCore
#endif

public struct MariaDBTransportConfiguration: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    public let database: String?
    public let tlsMode: ConnectionTLSMode

    public init(
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
