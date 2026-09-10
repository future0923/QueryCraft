import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLiteWorkspaceRestorationRepositoryTests {
    @Test func savesOrdersUpdatesAndDeletesWorkspaceState() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let repository = SQLiteWorkspaceRestorationRepository(
            database: database
        )
        let profile = makeProfile()
        try await profileRepository.insert(profile)

        let later = makeState(
            profileID: profile.id,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let earlier = makeState(
            profileID: profile.id,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try await repository.save(later)
        try await repository.save(earlier)

        #expect(try await repository.fetchAll() == [earlier, later])

        let updated = WorkspaceRestorationState(
            id: earlier.id,
            connectionProfileID: profile.id,
            databaseContexts: earlier.databaseContexts,
            selectedDatabaseContextID: earlier.selectedDatabaseContextID,
            windowFrame: nil,
            createdAt: earlier.createdAt,
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        try await repository.save(updated)

        #expect(try await repository.fetch(id: earlier.id) == updated)

        try await repository.delete(id: later.id)
        #expect(try await repository.fetchAll() == [updated])
    }

    @Test func profileDeletionCascadesToWorkspaceState() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let repository = SQLiteWorkspaceRestorationRepository(
            database: database
        )
        let profile = makeProfile()
        let state = makeState(profileID: profile.id)
        try await profileRepository.insert(profile)
        try await repository.save(state)

        try await profileRepository.delete(id: profile.id)

        #expect(try await repository.fetch(id: state.id) == nil)
    }

    @Test func refusesWorkspaceStateWithoutOwningProfile() async {
        let repository = SQLiteWorkspaceRestorationRepository(
            databaseURL: nil
        )

        do {
            try await repository.save(makeState(profileID: UUID()))
            Issue.record(
                "Expected workspace state without its Profile to fail."
            )
        } catch {
            // The ownership foreign key is enforced by SQLite.
        }
    }

    private func makeState(
        profileID: ConnectionProfile.ID,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> WorkspaceRestorationState {
        let documentID = UUID()
        let contextID = UUID()
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let document = WorkspaceQueryDocumentRestorationState(
            id: documentID,
            title: "Recent Users",
            savedQueryID: UUID(),
            defaultDatabase: "app"
        )
        return WorkspaceRestorationState(
            id: UUID(),
            connectionProfileID: profileID,
            databaseContexts: [
                WorkspaceDatabaseContextRestorationState(
                    id: contextID,
                    databaseName: "app",
                    selectedObject: selection,
                    queryDocuments: [document],
                    selectedQueryDocumentID: documentID,
                    contentTabOrder: [
                        .queryDocument(documentID),
                        .databaseObject(selection),
                    ],
                    selectedContentTab: .databaseObject(selection),
                    sidebarMode: .items
                )
            ],
            selectedDatabaseContextID: contextID,
            windowFrame: WorkspaceWindowFrame(
                x: 40,
                y: 80,
                width: 1_080,
                height: 720
            ),
            createdAt: createdAt,
            updatedAt: createdAt
        )
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
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}
