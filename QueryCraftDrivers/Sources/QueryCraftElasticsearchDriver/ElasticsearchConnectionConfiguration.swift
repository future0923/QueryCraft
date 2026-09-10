import Foundation
import QueryCraftFeature

struct ElasticsearchConnectionConfiguration: Equatable, Sendable {
    let host: String
    let port: Int
    let authentication: DatabaseConnectionAuthentication
    let tlsMode: ConnectionTLSMode

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .elasticsearch,
              configuration.databaseProduct == .elasticsearch
        else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .elasticsearch,
                actual: configuration.databaseType
            )
        }
        host = configuration.host
        port = configuration.port
        authentication = configuration.authentication
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
