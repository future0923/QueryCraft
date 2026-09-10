import Foundation

protocol ConnectionManagementRepository: ConnectionProfileRepository {
    func fetchManagementSnapshot() async throws -> ConnectionManagementSnapshot
    func update(_ profile: ConnectionProfile) async throws

    func insert(_ group: ConnectionGroup) async throws
    func update(_ group: ConnectionGroup) async throws

    func deletionImpact(
        profileIDs: [ConnectionProfile.ID]
    ) async throws -> ConnectionDeletionImpact
    func deleteProfiles(ids: [ConnectionProfile.ID]) async throws
    func deleteGroup(id: ConnectionGroup.ID) async throws

    func moveProfile(
        id: ConnectionProfile.ID,
        toGroupID: ConnectionGroup.ID?,
        beforeProfileID: ConnectionProfile.ID?
    ) async throws
    func moveGroup(
        id: ConnectionGroup.ID,
        beforeGroupID: ConnectionGroup.ID?
    ) async throws
}
