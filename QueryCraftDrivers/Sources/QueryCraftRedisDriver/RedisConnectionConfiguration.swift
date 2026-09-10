import QueryCraftFeature

struct RedisConnectionConfiguration: Equatable, Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let databaseIndex: Int

    init(_ configuration: DatabaseConnectionConfiguration) throws {
        guard configuration.databaseType == .redis else {
            throw DatabaseDriverError.configurationTypeMismatch(
                expected: .redis,
                actual: configuration.databaseType
            )
        }
        guard case .usernamePassword = configuration.authentication else {
            throw DatabaseDriverError.unsupportedAuthentication(
                databaseType: .redis,
                method: configuration.authentication.method
            )
        }
        guard configuration.tlsMode == .disabled else {
            throw RedisWorkspaceError.unsupportedTLS
        }
        guard let databaseIndex = Self.databaseIndex(
            from: configuration.database
        ) else {
            throw RedisWorkspaceError.invalidLogicalDatabase(
                configuration.database ?? ""
            )
        }
        host = configuration.host
        port = configuration.port
        username = configuration.username
        password = configuration.password
        self.databaseIndex = databaseIndex
    }

    static func databaseIndex(from name: String?) -> Int? {
        guard let name, !name.isEmpty else { return 0 }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawIndex: Substring
        if trimmed.lowercased().hasPrefix("db ") {
            rawIndex = trimmed.dropFirst(3)
        } else {
            rawIndex = Substring(trimmed)
        }
        guard let index = Int(rawIndex), index >= 0 else { return nil }
        return index
    }
}
