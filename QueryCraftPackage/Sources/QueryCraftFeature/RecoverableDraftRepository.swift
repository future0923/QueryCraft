import Foundation

protocol RecoverableDraftRepository: Sendable {
    func fetchAll(workspaceID: UUID) async throws -> [RecoverableDraft]
    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [RecoverableDraft]
    func fetch(id: RecoverableDraft.ID) async throws -> RecoverableDraft?
    func save(_ draft: RecoverableDraft) async throws
    func delete(id: RecoverableDraft.ID) async throws
    func deleteAll(workspaceID: UUID) async throws
}
