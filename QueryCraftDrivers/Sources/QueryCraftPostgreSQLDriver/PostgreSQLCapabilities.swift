struct PostgreSQLCapabilities: Equatable, Sendable {
    let serverVersion: Int

    static let unknown = Self(serverVersion: 0)

    var hasIdentityColumns: Bool { serverVersion >= 100_000 }
    var hasGeneratedColumns: Bool { serverVersion >= 120_000 }
    var hasDatabaseICULocale: Bool { serverVersion >= 150_000 }
    var hasModernICUSyntax: Bool { serverVersion >= 160_000 }
    var hasDatabaseLocale: Bool { serverVersion >= 170_000 }
}
