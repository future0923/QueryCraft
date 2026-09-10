import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite("Workspace Database Contexts")
struct WorkspaceDatabaseContextTests {
    @Test("First database adopts neutral queries")
    func firstDatabaseAdoptsNeutralQueries() async throws {
        let fixture = makeFixture()
        let model = fixture.model
        _ = await model.connect()

        let document = try #require(model.createQueryDocument())
        #expect(model.databaseContextName == nil)
        #expect(document.databaseName == nil)

        let requiresSessionReconnect = await model.adoptDatabaseContext("app")

        #expect(requiresSessionReconnect)
        #expect(model.databaseContextName == "app")
        #expect(document.databaseName == "app")
        #expect(model.queryDocuments.map(\.id) == [document.id])

        let repeatedAdoptionRequiresReconnect = await model
            .adoptDatabaseContext("app")
        #expect(!repeatedAdoptionRequiresReconnect)
        await model.disconnect()
    }

    @Test("Sibling databases share safety lock but not documents")
    func siblingDatabasesKeepIndependentDocuments() async throws {
        let fixture = makeFixture()
        let first = fixture.model
        _ = await first.connect()
        await first.adoptDatabaseContext("app")
        let firstDocument = try #require(first.createQueryDocument())

        let second = first.makeSibling(databaseName: "archive")
        _ = await second.connect()
        let secondDocument = try #require(second.createQueryDocument())

        #expect(first.safetyLock === second.safetyLock)
        #expect(firstDocument.databaseName == "app")
        #expect(secondDocument.databaseName == "archive")
        #expect(first.queryDocuments.map(\.id) == [firstDocument.id])
        #expect(second.queryDocuments.map(\.id) == [secondDocument.id])

        await first.disconnect()
        await second.disconnect()
    }

    @Test("Saved queries auto reload clean copies and preserve dirty copies")
    func savedQueryRefreshRespectsLocalEdits() async throws {
        let profile = makeProfile()
        let savedQueries = InMemorySavedQueryRepository()
        let first = makeModel(profile: profile, savedQueries: savedQueries)
        let second = makeModel(profile: profile, savedQueries: savedQueries)
        _ = await first.connect()
        _ = await second.connect()
        await first.adoptDatabaseContext("app")
        await second.adoptDatabaseContext("archive")

        let source = try #require(first.createQueryDocument())
        source.sql = "SELECT 1;"
        let saved = try await first.saveQueryDocument(source.id, name: "Q")

        _ = await second.refreshSavedQueriesFromRepository()
        let copy = try #require(
            second.openSavedQueryDocument(saved.id)?.document
        )

        source.sql = "SELECT 2;"
        _ = try await first.saveQueryDocument(source.id)
        let cleanChanges = await second.refreshSavedQueriesFromRepository()
        #expect(cleanChanges.isEmpty)
        #expect(copy.sql == "SELECT 2;")

        copy.sql = "SELECT 3;"
        source.sql = "SELECT 4;"
        _ = try await first.saveQueryDocument(source.id)
        let dirtyChanges = await second.refreshSavedQueriesFromRepository()

        #expect(dirtyChanges.count == 1)
        #expect(copy.sql == "SELECT 3;")
        guard case let .changed(document, query) = dirtyChanges[0] else {
            Issue.record("Expected a changed Saved Query conflict")
            return
        }
        #expect(document === copy)
        #expect(query.sql == "SELECT 4;")

        await second.ignoreQueryDocumentExternalChange(copy, from: query)
        let repeatedChanges = await second.refreshSavedQueriesFromRepository()
        #expect(repeatedChanges.isEmpty)
        #expect(copy.sql == "SELECT 3;")
        #expect(copy.isDirty)

        source.sql = "SELECT 5;"
        _ = try await first.saveQueryDocument(source.id)
        let newerChanges = await second.refreshSavedQueriesFromRepository()
        #expect(newerChanges.count == 1)
        guard case let .changed(_, newerQuery) = newerChanges[0] else {
            Issue.record("Expected a newer Saved Query conflict")
            return
        }
        #expect(newerQuery.sql == "SELECT 5;")

        await first.disconnect()
        await second.disconnect()
    }

    @Test("Ignoring a deleted Saved Query detaches it without repeated prompts")
    func ignoredSavedQueryDeletionDoesNotRepeat() async throws {
        let profile = makeProfile()
        let savedQueries = InMemorySavedQueryRepository()
        let first = makeModel(profile: profile, savedQueries: savedQueries)
        let second = makeModel(profile: profile, savedQueries: savedQueries)
        _ = await first.connect()
        _ = await second.connect()

        let source = try #require(first.createQueryDocument())
        source.sql = "SELECT 1;"
        let saved = try await first.saveQueryDocument(source.id, name: "Q")
        _ = await second.refreshSavedQueriesFromRepository()
        let copy = try #require(
            second.openSavedQueryDocument(saved.id)?.document
        )

        try await first.deleteSavedQuery(saved.id)
        let deletionChanges = await second.refreshSavedQueriesFromRepository()
        #expect(deletionChanges.count == 1)
        guard case let .deleted(document) = deletionChanges[0] else {
            Issue.record("Expected a deleted Saved Query conflict")
            return
        }

        second.detachDeletedQueryDocument(document)
        let repeatedChanges = await second.refreshSavedQueriesFromRepository()
        #expect(repeatedChanges.isEmpty)
        #expect(copy.savedQueryID == nil)
        #expect(copy.sql == "SELECT 1;")
        #expect(copy.isDirty)

        await first.disconnect()
        await second.disconnect()
    }

    @Test("Restoration keeps ordered database contexts")
    func restorationKeepsDatabaseContexts() {
        let profile = makeProfile()
        let firstID = UUID()
        let secondID = UUID()
        let contexts = [
            WorkspaceDatabaseContextRestorationState(
                id: firstID,
                databaseName: "app",
                selectedObject: nil,
                queryDocuments: [],
                selectedQueryDocumentID: nil,
                contentTabOrder: [],
                selectedContentTab: nil,
                sidebarMode: .items
            ),
            WorkspaceDatabaseContextRestorationState(
                id: secondID,
                databaseName: "archive",
                selectedObject: nil,
                queryDocuments: [],
                selectedQueryDocumentID: nil,
                contentTabOrder: [],
                selectedContentTab: nil,
                sidebarMode: .queries
            ),
        ]
        let state = WorkspaceRestorationState(
            id: UUID(),
            connectionProfileID: profile.id,
            databaseContexts: contexts,
            selectedDatabaseContextID: secondID,
            windowFrame: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let group = WorkspaceWindowGroup(
            restorationState: state,
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            didClose: { _ in }
        )

        #expect(group.databaseContexts.map(\.id) == [firstID, secondID])
        #expect(group.selectedContextID == secondID)
        #expect(group.model.databaseContextName == "archive")
        #expect(group.model.sidebarMode == .queries)
        #expect(
            group.databaseContexts[0].model.safetyLock
                === group.databaseContexts[1].model.safetyLock
        )
    }

    @Test("Moving a database preserves its context identity")
    func movingDatabasePreservesContextIdentity() async {
        let profile = makeProfile()
        let firstID = UUID()
        let secondID = UUID()
        let state = WorkspaceRestorationState(
            id: UUID(),
            connectionProfileID: profile.id,
            databaseContexts: [
                emptyContext(id: firstID, databaseName: "app"),
                emptyContext(id: secondID, databaseName: "archive"),
            ],
            selectedDatabaseContextID: secondID,
            windowFrame: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let group = WorkspaceWindowGroup(
            restorationState: state,
            restorationRepository: InMemoryWorkspaceRestorationRepository(),
            didClose: { _ in }
        )
        let context = group.databaseContexts[1]
        let newWorkspaceID = UUID()

        let transfer = group.extractDatabaseContext(secondID)
        await transfer?.0.model.moveToWorkspace(newWorkspaceID)

        #expect(transfer?.0 === context)
        #expect(context.model.workspaceID == newWorkspaceID)
        #expect(group.databaseContexts.map(\.id) == [firstID])
        #expect(group.selectedContextID == firstID)
    }

    @Test("Restoration does not duplicate another database draft")
    func restorationDoesNotDuplicateAnotherDatabaseDraft() async throws {
        let profile = makeProfile()
        let workspaceID = UUID()
        let firstDocumentID = UUID()
        let secondDocumentID = UUID()
        let firstContext = contextWithDocument(
            databaseName: "app",
            documentID: firstDocumentID
        )
        let secondContext = contextWithDocument(
            databaseName: "archive",
            documentID: secondDocumentID
        )
        let drafts = InMemoryRecoverableDraftRepository(drafts: [
            recoverableDraft(
                id: firstDocumentID,
                workspaceID: workspaceID,
                profileID: profile.id,
                databaseName: "app"
            ),
            recoverableDraft(
                id: secondDocumentID,
                workspaceID: workspaceID,
                profileID: profile.id,
                databaseName: "archive"
            ),
        ])
        let first = restorationModel(
            profile: profile,
            workspaceID: workspaceID,
            context: firstContext,
            drafts: drafts,
            recoversUnassignedDrafts: true,
            excludedDraftIDs: [secondDocumentID]
        )
        let second = restorationModel(
            profile: profile,
            workspaceID: workspaceID,
            context: secondContext,
            drafts: drafts,
            recoversUnassignedDrafts: false,
            excludedDraftIDs: [firstDocumentID]
        )

        _ = await first.connect()
        _ = await second.connect()

        #expect(first.queryDocuments.map(\.id) == [firstDocumentID])
        #expect(second.queryDocuments.map(\.id) == [secondDocumentID])

        await first.disconnect()
        await second.disconnect()
    }

    @Test("Moving a database moves its recoverable drafts")
    func movingDatabaseMovesRecoverableDrafts() async throws {
        let profile = makeProfile()
        let drafts = InMemoryRecoverableDraftRepository()
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            recoverableDraftRepository: drafts,
            recoverableDraftSaveDelay: .zero,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app", "archive"]
            )
        )
        _ = await model.connect()
        let oldWorkspaceID = model.workspaceID
        let document = try #require(model.createQueryDocument())
        document.sql = "SELECT 1;"
        await model.waitForRecoverableDraftPersistence()
        #expect(
            try await drafts.fetch(id: document.id)?.workspaceID
                == oldWorkspaceID
        )

        let newWorkspaceID = UUID()
        await model.moveToWorkspace(newWorkspaceID)

        #expect(model.workspaceID == newWorkspaceID)
        #expect(
            try await drafts.fetch(id: document.id)?.workspaceID
                == newWorkspaceID
        )
        await model.disconnect()
    }

    private func makeFixture() -> (
        model: WorkspaceModel,
        savedQueries: InMemorySavedQueryRepository
    ) {
        let profile = makeProfile()
        let savedQueries = InMemorySavedQueryRepository()
        return (
            makeModel(profile: profile, savedQueries: savedQueries),
            savedQueries
        )
    }

    private func emptyContext(
        id: UUID,
        databaseName: String
    ) -> WorkspaceDatabaseContextRestorationState {
        WorkspaceDatabaseContextRestorationState(
            id: id,
            databaseName: databaseName,
            selectedObject: nil,
            queryDocuments: [],
            selectedQueryDocumentID: nil,
            contentTabOrder: [],
            selectedContentTab: nil,
            sidebarMode: .items
        )
    }

    private func contextWithDocument(
        databaseName: String,
        documentID: UUID
    ) -> WorkspaceDatabaseContextRestorationState {
        let document = WorkspaceQueryDocumentRestorationState(
            id: documentID,
            title: "Query",
            savedQueryID: nil,
            defaultDatabase: databaseName
        )
        return WorkspaceDatabaseContextRestorationState(
            id: UUID(),
            databaseName: databaseName,
            selectedObject: nil,
            queryDocuments: [document],
            selectedQueryDocumentID: documentID,
            contentTabOrder: [.queryDocument(documentID)],
            selectedContentTab: .queryDocument(documentID),
            sidebarMode: .items
        )
    }

    private func recoverableDraft(
        id: UUID,
        workspaceID: UUID,
        profileID: ConnectionProfile.ID,
        databaseName: String
    ) -> RecoverableDraft {
        RecoverableDraft(
            id: id,
            workspaceID: workspaceID,
            connectionProfileID: profileID,
            defaultDatabase: databaseName,
            sql: "SELECT 1;",
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func restorationModel(
        profile: ConnectionProfile,
        workspaceID: UUID,
        context: WorkspaceDatabaseContextRestorationState,
        drafts: InMemoryRecoverableDraftRepository,
        recoversUnassignedDrafts: Bool,
        excludedDraftIDs: Set<UUID>
    ) -> WorkspaceModel {
        let state = WorkspaceRestorationState(
            id: workspaceID,
            connectionProfileID: profile.id,
            databaseContexts: [context],
            selectedDatabaseContextID: context.id,
            windowFrame: nil,
            createdAt: .now,
            updatedAt: .now
        )
        return WorkspaceModel(
            profileID: profile.id,
            workspaceID: workspaceID,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            recoverableDraftRepository: drafts,
            restorationState: state,
            databaseContextName: context.databaseName,
            recoversUnassignedDrafts: recoversUnassignedDrafts,
            excludedRecoverableDraftIDs: excludedDraftIDs,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app", "archive"]
            )
        )
    }

    private func makeModel(
        profile: ConnectionProfile,
        savedQueries: InMemorySavedQueryRepository
    ) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: savedQueries,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app", "archive"]
            )
        )
    }

    private func makeProfile() -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "Local",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }
}
