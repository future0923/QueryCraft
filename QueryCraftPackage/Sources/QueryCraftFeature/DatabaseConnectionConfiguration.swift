public enum DatabaseConnectionAuthentication: Equatable, Sendable {
    case usernamePassword(username: String, password: String?)
    case apiKey(String?)
    case none

    public var method: DatabaseConnectionAuthenticationMethod {
        switch self {
        case .usernamePassword: .usernamePassword
        case .apiKey: .apiKey
        case .none: .none
        }
    }
}

public enum DatabaseConnectionAuthenticationMethod:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Sendable
{
    case usernamePassword
    case apiKey
    case none

    public var id: String { rawValue }
}

public struct DatabaseConnectionConfiguration: Equatable, Sendable {
    public let databaseType: DatabaseType
    public let databaseProduct: DatabaseProduct
    public let host: String
    public let port: Int
    public let authentication: DatabaseConnectionAuthentication
    public let database: String?
    public let tlsMode: ConnectionTLSMode

    public init(
        databaseType: DatabaseType = .mysql,
        databaseProduct: DatabaseProduct? = nil,
        host: String,
        port: Int,
        username: String,
        password: String?,
        database: String?,
        tlsMode: ConnectionTLSMode
    ) {
        self.init(
            databaseType: databaseType,
            databaseProduct: databaseProduct,
            host: host,
            port: port,
            authentication: .usernamePassword(
                username: username,
                password: password
            ),
            database: database,
            tlsMode: tlsMode
        )
    }

    public init(
        databaseType: DatabaseType = .mysql,
        databaseProduct: DatabaseProduct? = nil,
        host: String,
        port: Int,
        authentication: DatabaseConnectionAuthentication,
        database: String?,
        tlsMode: ConnectionTLSMode
    ) {
        let resolvedProduct = databaseProduct
            ?? DatabaseProduct.defaultProduct(for: databaseType)
        self.databaseType = resolvedProduct.databaseType
        self.databaseProduct = resolvedProduct
        self.host = host
        self.port = port
        self.authentication = authentication
        self.database = database
        self.tlsMode = tlsMode
    }

    public var username: String {
        guard case .usernamePassword(let username, _) = authentication else {
            return ""
        }
        return username
    }

    public var password: String? {
        switch authentication {
        case .usernamePassword(_, let password), .apiKey(let password):
            password
        case .none:
            nil
        }
    }

    public func selecting(database: String?) -> Self {
        Self(
            databaseType: databaseType,
            databaseProduct: databaseProduct,
            host: host,
            port: port,
            authentication: authentication,
            database: database,
            tlsMode: tlsMode
        )
    }
}
