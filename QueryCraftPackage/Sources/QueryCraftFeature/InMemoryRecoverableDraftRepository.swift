import Foundation

actor InMemoryRecoverableDraftRepository: RecoverableDraftRepository {
    private var drafts: [RecoverableDraft]

    init(drafts: [RecoverableDraft] = []) {
        self.drafts = drafts
    }

    func fetchAll(workspaceID: UUID) async throws -> [RecoverableDraft] {
        drafts
            .filter { $0.workspaceID == workspaceID }
            .sorted(by: Self.areInRecoveryOrder)
    }

    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [RecoverableDraft] {
        drafts
            .filter {
                $0.connectionProfileID == connectionProfileID
            }
            .sorted(by: Self.areInRecoveryOrder)
    }

    func fetch(id: RecoverableDraft.ID) async throws -> RecoverableDraft? {
        drafts.first { $0.id == id }
    }

    func save(_ draft: RecoverableDraft) async throws {
        drafts.removeAll { $0.id == draft.id }
        drafts.append(draft)
    }

    func delete(id: RecoverableDraft.ID) async throws {
        drafts.removeAll { $0.id == id }
    }

    func deleteAll(workspaceID: UUID) async throws {
        drafts.removeAll { $0.workspaceID == workspaceID }
    }

    private static func areInRecoveryOrder(
        _ left: RecoverableDraft,
        _ right: RecoverableDraft
    ) -> Bool {
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }
}
