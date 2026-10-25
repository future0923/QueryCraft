import Foundation
import QueryCraftMobileCore

/// Native mobile transport uses the same driver session implementations and
/// optional COPY/LOCAL INFILE capabilities as the desktop transfer workbench.
struct DefaultWorkspaceSessionFactory: WorkspaceSessionFactory {
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession {
        do {
            if configuration.databaseType == .mysql || configuration.databaseType == .doris {
                guard configuration.tlsMode == .disabled || configuration.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
            }
            switch configuration.databaseType {
            case .mysql: return MySQLWorkspaceSession(configuration: try .init(configuration))
            case .postgresql: return PostgreSQLWorkspaceSession(configuration: try .init(configuration))
            case .doris: return DorisWorkspaceSession(configuration: try .init(configuration))
            default: throw DatabaseDriverError.notInstalled(configuration.databaseType)
            }
        } catch { return UnavailableDatabaseWorkspaceSession(error: error) }
    }
}

extension MobileSQLConfiguration {
    var sharedConfiguration: DatabaseConnectionConfiguration {
        .init(databaseType: driver == .postgresql ? .postgresql : driver == .doris ? .doris : .mysql,
            host: host, port: port, username: username, password: password, database: database, tlsMode: tlsMode)
    }
}
