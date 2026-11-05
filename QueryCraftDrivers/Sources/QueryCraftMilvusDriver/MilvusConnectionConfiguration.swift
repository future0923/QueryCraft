import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

struct MilvusConnectionConfiguration: Sendable {
    let host: String
    let port: Int
    let authentication: DatabaseConnectionAuthentication
    let database: String?
    let tlsMode: ConnectionTLSMode

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .milvus,
              configuration.databaseProduct == .milvus else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .milvus, actual: configuration.databaseType
            )
        }
        host = configuration.host
        port = configuration.port
        authentication = configuration.authentication
        database = configuration.database
        tlsMode = configuration.tlsMode
    }

    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = tlsMode == .disabled ? "http" : "https"
        components.host = host
        components.port = port
        return components.url
    }
}
