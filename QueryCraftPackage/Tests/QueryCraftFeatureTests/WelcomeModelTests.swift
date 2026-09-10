import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WelcomeModelTests {
    @Test func duplicateCopiesSettingsWithoutCredential() async throws {
        let group = makeGroup(name: "Development")
        let profile = makeProfile(
            name: "Local",
            groupID: group.id,
            storesCredential: true
        )
        let repository = InMemoryConnectionProfileRepository(
            profiles: [profile],
            groups: [group]
        )
        let credentialStore = InMemoryCredentialStore(
            passwords: [profile.id: "secret"]
        )
        let model = WelcomeModel(
            repository: repository,
            credentialStore: credentialStore,
            connectionTester: InMemoryConnectionTester(),
            profiles: [profile],
            groups: [group]
        )

        let duplicate = try await model.duplicateProfile(profile)

        #expect(
            duplicate.name
                == AppCopy.current.text("Local 副本", "Local Copy")
        )
        #expect(duplicate.groupID == group.id)
        #expect(duplicate.host == profile.host)
        #expect(duplicate.tlsMode == profile.tlsMode)
        #expect(!duplicate.storesCredential)
        #expect(
            try await credentialStore.password(for: duplicate.id) == nil
        )
        #expect(
            try await credentialStore.password(for: profile.id) == "secret"
        )
    }

    @Test func editingUpdatesCredentialAndMovesToEndOfGroup() async throws {
        let firstGroup = makeGroup(name: "Development", sortIndex: 0)
        let secondGroup = makeGroup(name: "Production", sortIndex: 1)
        let profile = makeProfile(
            name: "Local",
            groupID: firstGroup.id,
            storesCredential: true
        )
        let existingDestination = makeProfile(
            name: "Primary",
            groupID: secondGroup.id,
            sortIndex: 0
        )
        let repository = InMemoryConnectionProfileRepository(
            profiles: [profile, existingDestination],
            groups: [firstGroup, secondGroup]
        )
        let credentialStore = InMemoryCredentialStore(
            passwords: [profile.id: "old-secret"]
        )
        let model = WelcomeModel(
            repository: repository,
            credentialStore: credentialStore,
            connectionTester: InMemoryConnectionTester(),
            profiles: [profile, existingDestination],
            groups: [firstGroup, secondGroup]
        )
        var draft = try await model.draft(for: profile)
        draft.name = "Local Updated"
        draft.groupID = secondGroup.id
        draft.password = "new-secret"

        try await model.updateProfile(profile, from: draft)

        let updated = try #require(
            model.profiles.first { $0.id == profile.id }
        )
        #expect(updated.name == "Local Updated")
        #expect(updated.groupID == secondGroup.id)
        #expect(updated.sortIndex == 1)
        #expect(
            try await credentialStore.password(for: profile.id)
                == "new-secret"
        )
    }

    @Test func refusesProfileAndGroupDeletionForOpenWorkspace() async throws {
        let group = makeGroup(name: "Development")
        let profile = makeProfile(name: "Local", groupID: group.id)
        let model = WelcomeModel(
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile],
                groups: [group]
            ),
            credentialStore: InMemoryCredentialStore(),
            connectionTester: InMemoryConnectionTester(),
            profiles: [profile],
            groups: [group],
            profileOwnsOpenWorkspace: { $0 == profile.id }
        )

        await #expect(
            throws: WelcomeManagementError.profileOwnsOpenWorkspace(
                profile.name
            )
        ) {
            try await model.deletionRequest(for: profile)
        }
        await #expect(
            throws: WelcomeManagementError.groupOwnsOpenWorkspace(
                groupName: group.name,
                profileName: profile.name
            )
        ) {
            try await model.deletionRequest(for: group)
        }
    }

    @Test func groupDeletionReportsAndCascadesOwnedContent() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let queryRepository = SQLiteSavedQueryRepository(database: database)
        let draftRepository = SQLiteRecoverableDraftRepository(
            database: database
        )
        let restorationRepository = SQLiteWorkspaceRestorationRepository(
            database: database
        )
        let group = makeGroup(name: "Development")
        let profile = makeProfile(
            name: "Local",
            groupID: group.id,
            storesCredential: true
        )
        try await profileRepository.insert(group)
        try await profileRepository.insert(profile)

        let createdAt = Date(timeIntervalSince1970: 1_000)
        let query = SavedQuery(
            id: UUID(),
            connectionProfileID: profile.id,
            defaultDatabase: nil,
            name: "Health Check",
            sql: "SELECT 1;",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let draft = RecoverableDraft(
            id: UUID(),
            workspaceID: UUID(),
            connectionProfileID: profile.id,
            defaultDatabase: nil,
            sql: "SELECT 2;",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let contextID = UUID()
        let restoration = WorkspaceRestorationState(
            id: UUID(),
            connectionProfileID: profile.id,
            databaseContexts: [
                WorkspaceDatabaseContextRestorationState(
                    id: contextID,
                    databaseName: nil,
                    selectedObject: nil,
                    queryDocuments: [],
                    selectedQueryDocumentID: nil,
                    contentTabOrder: [],
                    selectedContentTab: nil,
                    sidebarMode: .items
                )
            ],
            selectedDatabaseContextID: contextID,
            windowFrame: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await queryRepository.insert(query)
        try await draftRepository.save(draft)
        try await restorationRepository.save(restoration)

        let credentialStore = InMemoryCredentialStore(
            passwords: [profile.id: "secret"]
        )
        let model = WelcomeModel(
            repository: profileRepository,
            credentialStore: credentialStore,
            connectionTester: InMemoryConnectionTester()
        )
        await model.loadProfiles()

        let request = try await model.deletionRequest(for: group)

        #expect(
            request.impact == ConnectionDeletionImpact(
                connectionProfileCount: 1,
                savedQueryCount: 1,
                recoverableDraftCount: 1,
                workspaceRestorationCount: 1,
                storedCredentialCount: 1
            )
        )

        try await model.delete(request)

        #expect(model.groups.isEmpty)
        #expect(model.profiles.isEmpty)
        #expect(try await queryRepository.fetch(id: query.id) == nil)
        #expect(try await draftRepository.fetch(id: draft.id) == nil)
        #expect(
            try await restorationRepository.fetch(id: restoration.id)
                == nil
        )
        #expect(
            try await credentialStore.password(for: profile.id) == nil
        )
    }

    @Test func rejectsDuplicateGroupNameIgnoringCase() async throws {
        let group = makeGroup(name: "Development")
        let model = WelcomeModel(
            repository: InMemoryConnectionProfileRepository(
                groups: [group]
            ),
            credentialStore: InMemoryCredentialStore(),
            connectionTester: InMemoryConnectionTester(),
            groups: [group]
        )

        await #expect(
            throws: WelcomeManagementError.duplicateGroupName(
                "development"
            )
        ) {
            try await model.createGroup(named: "development")
        }
    }

    @Test func refusesStaleDeletionConfirmation() async throws {
        let group = makeGroup(name: "Development")
        let profile = makeProfile(name: "Local", groupID: group.id)
        let repository = InMemoryConnectionProfileRepository(
            profiles: [profile],
            groups: [group]
        )
        let model = WelcomeModel(
            repository: repository,
            credentialStore: InMemoryCredentialStore(),
            connectionTester: InMemoryConnectionTester(),
            profiles: [profile],
            groups: [group]
        )
        let request = try await model.deletionRequest(for: group)
        try await model.duplicateProfile(profile)

        await #expect(
            throws: WelcomeManagementError.deletionContentsChanged
        ) {
            try await model.delete(request)
        }
    }

    private func makeGroup(
        name: String,
        sortIndex: Int = 0
    ) -> ConnectionGroup {
        ConnectionGroup(
            id: UUID(),
            name: name,
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeProfile(
        name: String,
        groupID: ConnectionGroup.ID?,
        storesCredential: Bool = false,
        sortIndex: Int = 0
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: name,
            groupID: groupID,
            host: "localhost",
            port: 3306,
            username: "root",
            defaultDatabase: "querycraft",
            tlsMode: .verifyIdentity,
            storesCredential: storesCredential,
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}
