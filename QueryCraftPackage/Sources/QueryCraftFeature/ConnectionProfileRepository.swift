protocol ConnectionProfileRepository: Sendable {
    func fetchAll() async throws -> [ConnectionProfile]
    func fetch(id: ConnectionProfile.ID) async throws -> ConnectionProfile?
    func insert(_ profile: ConnectionProfile) async throws
    func delete(id: ConnectionProfile.ID) async throws
}
