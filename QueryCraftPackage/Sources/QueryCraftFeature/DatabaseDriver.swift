import Foundation

public protocol DatabaseDriver: Sendable {
    var databaseType: DatabaseType { get }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession

    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> (any WorkspaceSession)?

    func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws
}

extension DatabaseDriver {
    public func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> (any WorkspaceSession)? {
        nil
    }
}

public enum DatabaseDriverError: LocalizedError, Equatable {
    case notInstalled(DatabaseType)
    case configurationTypeMismatch(
        expected: DatabaseType,
        actual: DatabaseType
    )
    case unsupportedAuthentication(
        databaseType: DatabaseType,
        method: DatabaseConnectionAuthenticationMethod
    )

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let databaseType):
            AppCopy.current.text(
                "尚未安装 \(databaseType.title) 驱动。",
                "The \(databaseType.title) driver is not installed."
            )
        case .configurationTypeMismatch(let expected, let actual):
            AppCopy.current.text(
                "\(expected.title) 驱动无法使用 \(actual.title) 连接配置。",
                "The \(expected.title) driver cannot use a \(actual.title) connection configuration."
            )
        case .unsupportedAuthentication(let databaseType, let method):
            AppCopy.current.text(
                "\(databaseType.title) 驱动不支持认证方式 \(method.title)。",
                "The \(databaseType.title) driver does not support \(method.title) authentication."
            )
        }
    }
}

public extension DatabaseConnectionAuthenticationMethod {
    var title: String {
        switch self {
        case .usernamePassword:
            AppCopy.current.text("用户名与密码", "Username and Password")
        case .apiKey:
            "API Key"
        case .none:
            AppCopy.current.text("无认证", "None")
        }
    }
}
