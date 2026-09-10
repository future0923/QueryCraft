import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceRecoverableDraftTests {
    @Test
    func automaticallyPersistsOnlyTheLatestDirtyContent() async throws {
        let profile = makeProfile()
        let draftRepository = InMemoryRecoverableDraftRepository()
        let model = makeModel(
            profile: profile,
            draftRepository: draftRepository
        )
        await model.connect()
        let document = try #require(model.createQueryDocument())

        document.sql = "SELECT 1;"
        document.sql = "SELECT * FROM users;"
        document.databaseName = "app"
        await model.waitForRecoverableDraftPersistence()

        let firstDraft = try #require(
            try await draftRepository.fetch(id: document.id)
        )
        #expect(firstDraft.id == document.id)
        #expect(firstDraft.workspaceID == model.workspaceID)
        #expect(firstDraft.connectionProfileID == profile.id)
        #expect(firstDraft.sql == "SELECT * FROM users;")
        #expect(firstDraft.defaultDatabase == "app")

        document.sql = "SELECT * FROM users WHERE active = TRUE;"
        await model.waitForRecoverableDraftPersistence()
        let updatedDraft = try #require(
            try await draftRepository.fetch(id: document.id)
        )
        #expect(updatedDraft.sql == document.sql)
        #expect(updatedDraft.createdAt == firstDraft.createdAt)
        #expect(updatedDraft.updatedAt >= firstDraft.updatedAt)

        await model.disconnect()
    }

    @Test
    func returningToThePersistedSnapshotRemovesTheDraft() async throws {
        let profile = makeProfile()
        let draftRepository = InMemoryRecoverableDraftRepository()
        let model = makeModel(
            profile: profile,
            draftRepository: draftRepository
        )
        await model.connect()
        let document = try #require(model.createQueryDocument())

        document.sql = "SELECT 1;"
        await model.waitForRecoverableDraftPersistence()
        #expect(try await draftRepository.fetch(id: document.id) != nil)

        document.sql = ""
        await model.waitForRecoverableDraftPersistence()

        #expect(!document.isDirty)
        #expect(try await draftRepository.fetch(id: document.id) == nil)
        await model.disconnect()
    }

    @Test
    func savingCleanDocumentDeletesItsRecoverableDraft() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(profileID: profile.id)
        let savedQueryRepository = InMemorySavedQueryRepository(
            queries: [savedQuery]
        )
        let draftRepository = InMemoryRecoverableDraftRepository()
        let model = makeModel(
            profile: profile,
            savedQueryRepository: savedQueryRepository,
            draftRepository: draftRepository
        )
        await model.connect()
        let document = try #require(
            model.openSavedQueryDocument(savedQuery.id)?.document
        )
        document.sql = "SELECT * FROM users WHERE active = TRUE;"
        await model.waitForRecoverableDraftPersistence()
        #expect(try await draftRepository.fetch(id: document.id) != nil)

        _ = try await model.saveQueryDocument(document.id)

        #expect(!document.isDirty)
        #expect(try await draftRepository.fetch(id: document.id) == nil)
        await model.disconnect()
    }

    @Test
    func editsMadeDuringSavedQueryWriteRemainRecoverable() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(profileID: profile.id)
        let savedQueryRepository = SuspendedUpdateSavedQueryRepository(
            queries: [savedQuery]
        )
        let draftRepository = InMemoryRecoverableDraftRepository()
        let model = makeModel(
            profile: profile,
            savedQueryRepository: savedQueryRepository,
            draftRepository: draftRepository
        )
        await model.connect()
        let document = try #require(
            model.openSavedQueryDocument(savedQuery.id)?.document
        )
        document.sql = "SELECT 1;"
        await model.waitForRecoverableDraftPersistence()

        let saveTask = Task {
            try await model.saveQueryDocument(document.id)
        }
        await savedQueryRepository.waitUntilUpdateStarts()
        document.sql = "SELECT 2;"
        await model.waitForRecoverableDraftPersistence()
        await savedQueryRepository.finishUpdate()
        _ = try await saveTask.value
        await model.waitForRecoverableDraftPersistence()

        let draft = try #require(
            try await draftRepository.fetch(id: document.id)
        )
        #expect(document.sql == "SELECT 2;")
        #expect(document.isDirty)
        #expect(draft.sql == "SELECT 2;")
        await model.disconnect()
    }

    @Test
    func recoversDraftsAsUnsavedDocumentsInTheExistingTabHost() async throws {
        let profile = makeProfile()
        let oldWorkspaceID = UUID()
        let first = makeDraft(
            id: UUID(),
            workspaceID: oldWorkspaceID,
            profileID: profile.id,
            databaseName: "app",
            sql: "SELECT 1;",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = makeDraft(
            id: UUID(),
            workspaceID: oldWorkspaceID,
            profileID: profile.id,
            databaseName: "removed_database",
            sql: "SELECT 2;",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let otherProfileDraft = makeDraft(
            id: UUID(),
            workspaceID: UUID(),
            profileID: UUID(),
            databaseName: nil,
            sql: "SELECT 3;",
            createdAt: Date(timeIntervalSince1970: 3_000)
        )
        let draftRepository = InMemoryRecoverableDraftRepository(
            drafts: [second, otherProfileDraft, first]
        )
        let model = makeModel(
            profile: profile,
            draftRepository: draftRepository
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(x: 30, y: 40, width: 1_080, height: 700)
        )
        let window = try #require(controller.window)
        let contentController = try #require(window.contentViewController)
        let frame = window.frame

        await model.connect()
        await group.restoreRecoveredQueryDocuments()

        #expect(model.queryDocuments.map(\.id) == [first.id, second.id])
        #expect(group.tabsModel.items.map(\.id) == [first.id, second.id])
        #expect(group.tabsModel.selectedDocumentID == second.id)
        #expect(model.selectedQueryDocumentID == second.id)
        #expect(window.contentViewController === contentController)
        #expect(window.frame == frame)

        let firstItem = try #require(group.tabsModel.items.first)
        let secondItem = try #require(group.tabsModel.items.last)
        #expect(firstItem.editorContext !== secondItem.editorContext)
        #expect(
            firstItem.document.title
                == AppCopy.current.text(
                    "已恢复查询 1",
                    "Recovered Query 1"
                )
        )
        #expect(firstItem.document.sql == first.sql)
        #expect(firstItem.document.databaseName == "app")
        #expect(firstItem.document.savedQueryID == nil)
        #expect(firstItem.document.isDirty)
        #expect(firstItem.document.executionState == .idle)
        #expect(firstItem.document.statementResults.isEmpty)
        #expect(firstItem.document.transactionState == .disconnected)
        #expect(secondItem.document.databaseName == "removed_database")
        #expect(secondItem.document.isDirty)

        secondItem.document.sql = "SELECT 4;"
        await model.waitForRecoverableDraftPersistence()
        let migratedDraft = try #require(
            try await draftRepository.fetch(id: second.id)
        )
        #expect(migratedDraft.workspaceID == model.workspaceID)
        #expect(migratedDraft.sql == "SELECT 4;")

        await model.disconnect()
    }

    @Test
    func recoveredDocumentsRemainAvailableWhenConnectionFails() async throws {
        let profile = makeProfile()
        let draft = makeDraft(
            id: UUID(),
            workspaceID: UUID(),
            profileID: profile.id,
            databaseName: "app",
            sql: "SELECT 1;",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let model = makeModel(
            profile: profile,
            draftRepository: InMemoryRecoverableDraftRepository(
                drafts: [draft]
            ),
            sessionFactory: FailingDatabaseListSessionFactory()
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })

        let session = await model.connect {
            await group.restoreRecoveredQueryDocuments()
        }

        #expect(session == nil)
        if case .failed = model.connectionState {
            // Expected: the recovered editor remains usable offline.
        } else {
            Issue.record("Expected the workspace connection to fail.")
        }
        #expect(model.queryDocuments.map(\.id) == [draft.id])
        #expect(group.tabsModel.items.map(\.id) == [draft.id])
        #expect(group.tabsModel.selectedItem?.document.sql == draft.sql)
        #expect(group.tabsModel.selectedItem?.document.isDirty == true)
    }

    @Test
    func intentionalCloseDeletesTheDraftWithoutReplacingWorkspace() async throws {
        let profile = makeProfile()
        let draftRepository = InMemoryRecoverableDraftRepository()
        let model = makeModel(
            profile: profile,
            draftRepository: draftRepository
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(x: 30, y: 40, width: 1_080, height: 700)
        )
        let window = try #require(controller.window)
        let contentController = try #require(window.contentViewController)
        let frame = window.frame
        await model.connect()
        group.createQueryDocument()
        let item = try #require(group.tabsModel.selectedItem)
        item.document.sql = "SELECT 1;"
        await model.waitForRecoverableDraftPersistence()

        let result = group.closeQueryDocumentInBackground(
            item.id,
            authorization: .discardingCurrentChanges(in: item.document)
        )
        await group.waitForPendingDocumentClosures()

        #expect(result == .closed)
        #expect(try await draftRepository.fetch(id: item.id) == nil)
        #expect(model.queryDocuments.isEmpty)
        #expect(group.tabsModel.items.isEmpty)
        #expect(window.contentViewController === contentController)
        #expect(window.frame == frame)
        await model.disconnect()
    }

    @Test
    func closeWaitsForInFlightDraftWriteBeforeDeletingIt() async throws {
        let profile = makeProfile()
        let draftRepository = SuspendedSaveDraftRepository()
        let model = makeModel(
            profile: profile,
            draftRepository: draftRepository
        )
        await model.connect()
        let document = try #require(model.createQueryDocument())
        document.sql = "SELECT 1;"
        await draftRepository.waitUntilSaveStarts()

        let closeTask = Task {
            await model.closeQueryDocument(
                document.id,
                authorization: .discardingCurrentChanges(in: document)
            )
        }
        await Task.yield()
        await draftRepository.finishSave()
        let result = await closeTask.value

        #expect(result == .closed)
        #expect(try await draftRepository.fetch(id: document.id) == nil)
        #expect(model.queryDocuments.isEmpty)
        await model.disconnect()
    }

    private func makeModel(
        profile: ConnectionProfile,
        savedQueryRepository: any SavedQueryRepository =
            InMemorySavedQueryRepository(),
        draftRepository: any RecoverableDraftRepository,
        sessionFactory: any WorkspaceSessionFactory =
            InMemoryWorkspaceSessionFactory(databases: ["app", "mysql"])
    ) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profile.id,
            workspaceID: UUID(),
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: savedQueryRepository,
            recoverableDraftRepository: draftRepository,
            recoverableDraftSaveDelay: .zero,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: sessionFactory
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

    private func makeSavedQuery(
        profileID: ConnectionProfile.ID
    ) -> SavedQuery {
        SavedQuery(
            id: UUID(),
            connectionProfileID: profileID,
            defaultDatabase: "app",
            name: "Recent Users",
            sql: "SELECT * FROM users;",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeDraft(
        id: UUID,
        workspaceID: UUID,
        profileID: ConnectionProfile.ID,
        databaseName: String?,
        sql: String,
        createdAt: Date
    ) -> RecoverableDraft {
        RecoverableDraft(
            id: id,
            workspaceID: workspaceID,
            connectionProfileID: profileID,
            defaultDatabase: databaseName,
            sql: sql,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private actor SuspendedUpdateSavedQueryRepository: SavedQueryRepository {
    private var queries: [SavedQuery]
    private var updateContinuation: CheckedContinuation<Void, Never>?

    init(queries: [SavedQuery]) {
        self.queries = queries
    }

    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [SavedQuery] {
        queries.filter {
            $0.connectionProfileID == connectionProfileID
        }
    }

    func fetch(id: SavedQuery.ID) async throws -> SavedQuery? {
        queries.first { $0.id == id }
    }

    func insert(_ query: SavedQuery) async throws {
        queries.append(query)
    }

    func update(_ query: SavedQuery) async throws {
        await withCheckedContinuation { continuation in
            updateContinuation = continuation
        }
        guard let index = queries.firstIndex(where: { $0.id == query.id })
        else {
            throw SavedQueryRepositoryError.queryNotFound
        }
        queries[index] = query
    }

    func delete(id: SavedQuery.ID) async throws {
        queries.removeAll { $0.id == id }
    }

    func waitUntilUpdateStarts() async {
        while updateContinuation == nil {
            await Task.yield()
        }
    }

    func finishUpdate() {
        updateContinuation?.resume()
        updateContinuation = nil
    }
}

private actor SuspendedSaveDraftRepository: RecoverableDraftRepository {
    private var drafts: [RecoverableDraft] = []
    private var saveContinuation: CheckedContinuation<Void, Never>?

    func fetchAll(workspaceID: UUID) async throws -> [RecoverableDraft] {
        drafts.filter { $0.workspaceID == workspaceID }
    }

    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [RecoverableDraft] {
        drafts.filter {
            $0.connectionProfileID == connectionProfileID
        }
    }

    func fetch(id: RecoverableDraft.ID) async throws -> RecoverableDraft? {
        drafts.first { $0.id == id }
    }

    func save(_ draft: RecoverableDraft) async throws {
        await withCheckedContinuation { continuation in
            saveContinuation = continuation
        }
        drafts.removeAll { $0.id == draft.id }
        drafts.append(draft)
    }

    func delete(id: RecoverableDraft.ID) async throws {
        drafts.removeAll { $0.id == id }
    }

    func deleteAll(workspaceID: UUID) async throws {
        drafts.removeAll { $0.workspaceID == workspaceID }
    }

    func waitUntilSaveStarts() async {
        while saveContinuation == nil {
            await Task.yield()
        }
    }

    func finishSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}

private struct FailingDatabaseListSessionFactory: WorkspaceSessionFactory {
    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        FailingDatabaseListSession()
    }
}

private actor FailingDatabaseListSession: WorkspaceSession {
    func connect() async throws {}

    func fetchDatabases() async throws -> [String] {
        throw FailingDatabaseListError.unavailable
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        throw FailingDatabaseListError.unavailable
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw FailingDatabaseListError.unavailable
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        throw FailingDatabaseListError.unavailable
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (
            WorkspaceDatabaseDataBatch
        ) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        throw FailingDatabaseListError.unavailable
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw FailingDatabaseListError.unavailable
    }

    func close() async {}
}

private enum FailingDatabaseListError: Error {
    case unavailable
}
