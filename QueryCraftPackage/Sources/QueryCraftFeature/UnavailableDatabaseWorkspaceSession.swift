actor UnavailableDatabaseWorkspaceSession: WorkspaceSession {
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func connect() async throws { throw error }
    func isConnected() async -> Bool { false }
    func fetchDatabases() async throws -> [String] { throw error }
    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        throw error
    }
    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        throw error
    }
    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw error
    }
    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        throw error
    }
    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        throw error
    }
    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw error
    }
    func close() async {}
}
