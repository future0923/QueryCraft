import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLiteRecoverableDraftRepositoryTests {
    @Test func savesReplacesAndDeletesDraftsWithinOneWorkspace() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let repository = SQLiteRecoverableDraftRepository(database: database)
        let profile = makeProfile()
        try await profileRepository.insert(profile)

        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let first = makeDraft(
            workspaceID: workspaceID,
            profileID: profile.id,
            sql: "SELECT 1;",
            createdAt: createdAt
        )
        let second = makeDraft(
            workspaceID: workspaceID,
            profileID: profile.id,
            sql: "SELECT 2;",
            createdAt: createdAt.addingTimeInterval(1)
        )
        let otherWorkspaceDraft = makeDraft(
            workspaceID: otherWorkspaceID,
            profileID: profile.id,
            sql: "SELECT 3;",
            createdAt: createdAt
        )

        try await repository.save(second)
        try await repository.save(otherWorkspaceDraft)
        try await repository.save(first)

        let profileDraftIDs = try await repository.fetchAll(
            connectionProfileID: profile.id
        ).map(\.id)
        #expect(
            Set(profileDraftIDs)
                == Set([first.id, second.id, otherWorkspaceDraft.id])
        )
        #expect(
            try await repository.fetchAll(workspaceID: workspaceID)
                == [first, second]
        )

        let replacement = RecoverableDraft(
            id: first.id,
            workspaceID: workspaceID,
            connectionProfileID: profile.id,
            defaultDatabase: "querycraft",
            sql: "SELECT * FROM users;",
            createdAt: first.createdAt,
            updatedAt: createdAt.addingTimeInterval(10)
        )
        try await repository.save(replacement)

        #expect(try await repository.fetch(id: first.id) == replacement)

        try await repository.delete(id: second.id)
        #expect(try await repository.fetch(id: second.id) == nil)

        try await repository.deleteAll(workspaceID: workspaceID)
        #expect(
            try await repository.fetchAll(workspaceID: workspaceID).isEmpty
        )
        #expect(
            try await repository.fetchAll(workspaceID: otherWorkspaceID)
                == [otherWorkspaceDraft]
        )
    }

    @Test func profileDeletionCascadesToQueriesAndDrafts() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let queryRepository = SQLiteSavedQueryRepository(database: database)
        let draftRepository = SQLiteRecoverableDraftRepository(
            database: database
        )
        let profile = makeProfile()
        try await profileRepository.insert(profile)

        let query = SavedQuery(
            id: UUID(),
            connectionProfileID: profile.id,
            defaultDatabase: nil,
            name: "Health Check",
            sql: "SELECT 1;",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let draft = makeDraft(
            workspaceID: UUID(),
            profileID: profile.id,
            sql: "SELECT 2;"
        )
        try await queryRepository.insert(query)
        try await draftRepository.save(draft)

        try await profileRepository.delete(id: profile.id)

        #expect(try await queryRepository.fetch(id: query.id) == nil)
        #expect(try await draftRepository.fetch(id: draft.id) == nil)
    }

    @Test func refusesDraftWithoutOwningProfile() async {
        let repository = SQLiteRecoverableDraftRepository(databaseURL: nil)
        let draft = makeDraft(
            workspaceID: UUID(),
            profileID: UUID(),
            sql: "SELECT 1;"
        )

        do {
            try await repository.save(draft)
            Issue.record("Expected a Draft without its Profile to fail.")
        } catch {
            // The ownership foreign key is enforced by SQLite.
        }
    }

    private func makeProfile() -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "Local",
            groupID: nil,
            host: "localhost",
            port: 3306,
            username: "root",
            defaultDatabase: nil,
            tlsMode: .verifyIdentity,
            storesCredential: false,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeDraft(
        workspaceID: UUID,
        profileID: ConnectionProfile.ID,
        sql: String,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> RecoverableDraft {
        RecoverableDraft(
            id: UUID(),
            workspaceID: workspaceID,
            connectionProfileID: profileID,
            defaultDatabase: nil,
            sql: sql,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
