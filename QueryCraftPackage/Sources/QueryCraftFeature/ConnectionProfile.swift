import Foundation
import GRDB

struct ConnectionProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let groupID: ConnectionGroup.ID?
    let databaseType: DatabaseType
    let databaseProduct: DatabaseProduct
    let host: String
    let port: Int
    let username: String
    let authenticationMethod: DatabaseConnectionAuthenticationMethod
    let defaultDatabase: String?
    let tlsMode: ConnectionTLSMode
    let storesCredential: Bool
    let sortIndex: Int
    let createdAt: Date

    init(
        id: UUID,
        name: String,
        groupID: ConnectionGroup.ID?,
        databaseType: DatabaseType = .mysql,
        databaseProduct: DatabaseProduct? = nil,
        host: String,
        port: Int,
        username: String,
        authenticationMethod: DatabaseConnectionAuthenticationMethod = .usernamePassword,
        defaultDatabase: String?,
        tlsMode: ConnectionTLSMode,
        storesCredential: Bool,
        sortIndex: Int = 0,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.groupID = groupID
        let resolvedProduct = databaseProduct
            ?? DatabaseProduct.defaultProduct(for: databaseType)
        self.databaseType = resolvedProduct.databaseType
        self.databaseProduct = resolvedProduct
        self.host = host
        self.port = port
        self.username = username
        self.authenticationMethod = authenticationMethod
        self.defaultDatabase = defaultDatabase
        self.tlsMode = tlsMode
        self.storesCredential = storesCredential
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

extension ConnectionProfile {
    func authentication(secret: String?) -> DatabaseConnectionAuthentication {
        switch authenticationMethod {
        case .usernamePassword:
            .usernamePassword(username: username, password: secret)
        case .apiKey:
            .apiKey(secret)
        case .none:
            .none
        }
    }
}

extension ConnectionProfile: FetchableRecord, PersistableRecord {
    static let databaseTableName = "connectionProfile"
}
