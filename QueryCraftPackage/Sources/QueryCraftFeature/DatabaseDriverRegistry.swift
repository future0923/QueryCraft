public actor DatabaseDriverRegistry {
    public static let shared = DatabaseDriverRegistry()

    private var drivers: [DatabaseType: any DatabaseDriver]

    public init(drivers: [any DatabaseDriver] = []) {
        self.drivers = Dictionary(
            uniqueKeysWithValues: drivers.map { ($0.databaseType, $0) }
        )
    }

    public func register(_ driver: any DatabaseDriver) {
        drivers[driver.databaseType] = driver
    }

    public func unregister(_ databaseType: DatabaseType) {
        drivers[databaseType] = nil
    }

    public func isInstalled(_ databaseType: DatabaseType) -> Bool {
        drivers[databaseType] != nil
    }

    public func driver(for databaseType: DatabaseType) -> (any DatabaseDriver)? {
        drivers[databaseType]
    }

    public func installedDatabaseTypes() -> Set<DatabaseType> {
        Set(drivers.keys)
    }

    public func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> any WorkspaceSession {
        guard let driver = drivers[configuration.databaseType] else {
            throw DatabaseDriverError.notInstalled(configuration.databaseType)
        }
        return try await driver.makeSession(configuration: configuration)
    }

    public func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async throws -> (any WorkspaceSession)? {
        guard let driver = drivers[configuration.databaseType] else {
            throw DatabaseDriverError.notInstalled(configuration.databaseType)
        }
        return try await driver.makeSchemaCatalogSession(
            configuration: configuration
        )
    }

    public func testConnection(
        configuration: DatabaseConnectionConfiguration
    ) async throws {
        guard let driver = drivers[configuration.databaseType] else {
            throw DatabaseDriverError.notInstalled(configuration.databaseType)
        }
        try await driver.testConnection(configuration: configuration)
    }
}

struct DefaultWorkspaceSessionFactory: WorkspaceSessionFactory {
    let registry: DatabaseDriverRegistry

    init(registry: DatabaseDriverRegistry = .shared) {
        self.registry = registry
    }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        do {
            return try await registry.makeSession(configuration: configuration)
        } catch {
            return UnavailableDatabaseWorkspaceSession(error: error)
        }
    }

    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> (any WorkspaceSession)? {
        try? await registry.makeSchemaCatalogSession(
            configuration: configuration
        )
    }
}

struct DatabaseDriverConnectionTester: ConnectionTester {
    let registry: DatabaseDriverRegistry

    init(registry: DatabaseDriverRegistry = .shared) {
        self.registry = registry
    }

    func test(
        _ configuration: DatabaseConnectionConfiguration
    ) async throws {
        try await registry.testConnection(configuration: configuration)
    }
}
