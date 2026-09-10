protocol SavedQueryRepository: Sendable {
    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [SavedQuery]
    func fetch(id: SavedQuery.ID) async throws -> SavedQuery?
    func insert(_ query: SavedQuery) async throws
    func update(_ query: SavedQuery) async throws
    func delete(id: SavedQuery.ID) async throws
}
