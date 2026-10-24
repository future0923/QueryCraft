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
