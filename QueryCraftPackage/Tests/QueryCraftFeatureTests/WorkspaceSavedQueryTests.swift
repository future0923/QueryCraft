import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceSavedQueryTests {
    @Test
    func loadsAndClassifiesSavedQueriesForTheObjectBrowser() async throws {
        let profile = makeProfile()
        let general = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: nil,
            name: "Server Status"
        )
        let databaseQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users"
        )
        let unavailable = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "removed_database",
            name: "Orphan Report"
        )
        let model = makeModel(
            profile: profile,
            savedQueries: [unavailable, databaseQuery, general]
        )

        await model.connect()

        #expect(model.visibleGeneralSavedQueries == [general])
        #expect(model.savedQueries(in: "app") == [databaseQuery])
        #expect(model.visibleUnavailableSavedQueries == [unavailable])

        model.searchText = "orphan"
        #expect(model.visibleGeneralSavedQueries.isEmpty)
        #expect(model.visibleDatabases.isEmpty)
        #expect(model.visibleUnavailableSavedQueries == [unavailable])

        let result = try #require(
            model.openSavedQueryDocument(unavailable.id)
        )
        await result.document.replaceConnectionConfiguration(
            DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "reader",
                password: nil,
                database: nil,
                tlsMode: .disabled
            ),
            availableDatabases: ["app", "mysql"]
        )
        #expect(result.document.databaseName == "removed_database")
        #expect(!result.document.isDirty)

        await model.disconnect()
    }

    @Test
    func reopeningSavedQueryReusesItsDocumentAndEditorContext() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users",
            sql: "SELECT * FROM users;"
        )
        let model = makeModel(
            profile: profile,
            savedQueries: [savedQuery]
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })

        await model.connect()
        group.openSavedQuery(savedQuery.id)
        let firstItem = try #require(group.tabsModel.selectedItem)
        let firstDocument = firstItem.document
        let firstContext = firstItem.editorContext

        group.openSavedQuery(savedQuery.id)

        #expect(model.queryDocuments.count == 1)
        #expect(group.tabsModel.items.count == 1)
        #expect(group.tabsModel.selectedItem?.document === firstDocument)
        #expect(group.tabsModel.selectedItem?.editorContext === firstContext)
        #expect(firstDocument.savedQueryID == savedQuery.id)
        #expect(firstDocument.title == savedQuery.name)
        #expect(firstDocument.sql == savedQuery.sql)
        #expect(firstDocument.databaseName == savedQuery.defaultDatabase)
        #expect(!firstDocument.isDirty)

        await model.disconnect()
    }

    @Test
    func savesNewQueryThenUpdatesTheSamePersistentIdentity() async throws {
        let profile = makeProfile()
        let repository = InMemorySavedQueryRepository()
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: repository,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
            )
        )

        await model.connect()
        let document = try #require(model.createQueryDocument())
        #expect(document.savedQueryID == nil)
        #expect(document.canSave)

        document.sql = "SELECT * FROM users;"
        document.databaseName = "app"
        #expect(document.isDirty)

        let createdAt = Date(timeIntervalSince1970: 1_000)
        let created = try await model.saveQueryDocument(
            document.id,
            name: "  Recent Users  ",
            now: createdAt
        )

        #expect(created.name == "Recent Users")
        #expect(created.defaultDatabase == "app")
        #expect(model.savedQueries(in: "app") == [created])
        #expect(document.savedQueryID == created.id)
        #expect(document.title == "Recent Users")
        #expect(!document.isDirty)
        #expect(!document.canSave)
        #expect(try await repository.fetch(id: created.id) == created)

        document.sql = "SELECT * FROM users WHERE active = TRUE;"
        #expect(document.isDirty)

        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let updated = try await model.saveQueryDocument(
            document.id,
            now: updatedAt
        )

        #expect(updated.id == created.id)
        #expect(updated.createdAt == createdAt)
        #expect(updated.updatedAt == updatedAt)
        #expect(updated.sql == document.sql)
        #expect(!document.isDirty)
        #expect(try await repository.fetch(id: created.id) == updated)

        await model.disconnect()
    }

    @Test
    func refusesDuplicateNameInTheSameSavedQueryScope() async throws {
        let profile = makeProfile()
        let repository = InMemorySavedQueryRepository()
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: repository,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
            )
        )

        await model.connect()
        let first = try #require(model.createQueryDocument())
        first.databaseName = "app"
        _ = try await model.saveQueryDocument(first.id, name: "Users")

        let second = try #require(model.createQueryDocument())
        second.databaseName = "app"
        await #expect(throws: SavedQueryRepositoryError.nameAlreadyExists) {
            try await model.saveQueryDocument(second.id, name: "Users")
        }
        #expect(second.savedQueryID == nil)
        #expect(!second.isSaving)

        await model.disconnect()
    }

    @Test
    func editsMadeDuringSaveRemainDirtyAfterSnapshotPersists() async throws {
        let profile = makeProfile()
        let repository = SuspendedSavedQueryRepository()
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: repository,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
            )
        )

        await model.connect()
        let document = try #require(model.createQueryDocument())
        document.sql = "SELECT 1;"
        let saveTask = Task {
            try await model.saveQueryDocument(
                document.id,
                name: "Snapshot"
            )
        }

        await repository.waitUntilInsertStarts()
        document.sql = "SELECT 2;"
        await repository.finishInsert()
        let savedQuery = try await saveTask.value

        #expect(savedQuery.sql == "SELECT 1;")
        #expect(document.sql == "SELECT 2;")
        #expect(document.isDirty)
        #expect(try await repository.fetch(id: savedQuery.id) == savedQuery)

        await model.disconnect()
    }

    @Test
    func savingDirtyQueryAllowsCloseWithoutDiscardAuthorization() async throws {
        let profile = makeProfile()
        let model = makeModel(profile: profile, savedQueries: [])

        await model.connect()
        let document = try #require(model.createQueryDocument())
        document.sql = "SELECT * FROM users;"

        #expect(
            await model.closeQueryDocument(document.id)
                == .needsUnsavedChangesDecision
        )
        #expect(model.queryDocuments.first === document)

        _ = try await model.saveQueryDocument(
            document.id,
            name: "Recent Users"
        )

        #expect(await model.closeQueryDocument(document.id) == .closed)
        #expect(model.queryDocuments.isEmpty)
        await model.disconnect()
    }

    @Test
    func renameUpdatesOpenDocumentWithoutReplacingWorkspaceOrEditor() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users"
        )
        let repository = InMemorySavedQueryRepository(queries: [savedQuery])
        let model = makeModel(profile: profile, repository: repository)
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(x: 40, y: 60, width: 1_100, height: 720)
        )

        await model.connect()
        group.openSavedQuery(savedQuery.id)
        let item = try #require(group.tabsModel.selectedItem)
        let editorContext = item.editorContext
        let window = try #require(controller.window)
        let contentController = try #require(window.contentViewController)
        let frame = window.frame
        let renamedAt = Date(timeIntervalSince1970: 2_000)

        let renamed = try await model.renameSavedQuery(
            savedQuery.id,
            name: "  Active Users  ",
            now: renamedAt
        )

        #expect(renamed.id == savedQuery.id)
        #expect(renamed.name == "Active Users")
        #expect(renamed.updatedAt == renamedAt)
        #expect(model.savedQuery(id: savedQuery.id) == renamed)
        #expect(try await repository.fetch(id: savedQuery.id) == renamed)
        #expect(item.document.title == "Active Users")
        #expect(!item.document.isDirty)
        #expect(group.tabsModel.selectedItem?.editorContext === editorContext)
        #expect(window.contentViewController === contentController)
        #expect(window.frame == frame)

        await model.disconnect()
    }

    @Test
    func duplicateChoosesSequentialCopyNamesInTheSameScope() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users",
            sql: "SELECT * FROM users;"
        )
        let repository = InMemorySavedQueryRepository(queries: [savedQuery])
        let model = makeModel(profile: profile, repository: repository)
        await model.connect()

        let copiedAt = Date(timeIntervalSince1970: 2_000)
        let firstCopy = try await model.duplicateSavedQuery(
            savedQuery.id,
            now: copiedAt
        )
        let secondCopy = try await model.duplicateSavedQuery(
            savedQuery.id,
            now: copiedAt
        )

        #expect(firstCopy.id != savedQuery.id)
        #expect(secondCopy.id != savedQuery.id)
        #expect(secondCopy.id != firstCopy.id)
        #expect(firstCopy.name == "Recent Users Copy")
        #expect(secondCopy.name == "Recent Users Copy 2")
        #expect(firstCopy.sql == savedQuery.sql)
        #expect(firstCopy.defaultDatabase == savedQuery.defaultDatabase)
        #expect(firstCopy.createdAt == copiedAt)
        #expect(firstCopy.updatedAt == copiedAt)
        #expect(try await repository.fetch(id: firstCopy.id) == firstCopy)
        #expect(try await repository.fetch(id: secondCopy.id) == secondCopy)

        await model.disconnect()
    }

    @Test
    func moveReclassifiesSavedQueryWhileRetainingItsIdentity() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "removed_database",
            name: "Recent Users"
        )
        let repository = InMemorySavedQueryRepository(queries: [savedQuery])
        let model = makeModel(profile: profile, repository: repository)
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        await model.connect()
        group.openSavedQuery(savedQuery.id)
        let document = try #require(group.tabsModel.selectedItem?.document)

        #expect(model.visibleUnavailableSavedQueries == [savedQuery])

        let general = try await model.moveSavedQuery(
            savedQuery.id,
            to: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        #expect(general.id == savedQuery.id)
        #expect(general.defaultDatabase == nil)
        #expect(model.visibleGeneralSavedQueries == [general])
        #expect(model.visibleUnavailableSavedQueries.isEmpty)
        #expect(document.databaseName == nil)
        #expect(!document.isDirty)

        let databaseQuery = try await model.moveSavedQuery(
            savedQuery.id,
            to: "app",
            now: Date(timeIntervalSince1970: 3_000)
        )
        #expect(databaseQuery.id == savedQuery.id)
        #expect(databaseQuery.defaultDatabase == "app")
        #expect(model.visibleGeneralSavedQueries.isEmpty)
        #expect(model.savedQueries(in: "app") == [databaseQuery])
        #expect(try await repository.fetch(id: savedQuery.id) == databaseQuery)
        #expect(document.databaseName == "app")
        #expect(!document.isDirty)

        await model.disconnect()
    }

    @Test
    func movePreservesAnIndependentDatabaseEditInTheOpenDocument() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users"
        )
        let repository = InMemorySavedQueryRepository(queries: [savedQuery])
        let model = makeModel(profile: profile, repository: repository)
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        await model.connect()
        group.openSavedQuery(savedQuery.id)
        let item = try #require(group.tabsModel.selectedItem)
        let editorContext = item.editorContext
        item.document.databaseName = "mysql"
        #expect(item.document.isDirty)

        let moved = try await model.moveSavedQuery(
            savedQuery.id,
            to: nil
        )

        #expect(moved.defaultDatabase == nil)
        #expect(item.document.databaseName == "mysql")
        #expect(item.document.isDirty)
        #expect(item.document.savedQueryID == savedQuery.id)
        #expect(group.tabsModel.selectedItem?.editorContext === editorContext)

        await model.disconnect()
    }

    @Test
    func deleteKeepsOpenDocumentAsDirtyUnsavedWork() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users",
            sql: "SELECT * FROM users;"
        )
        let repository = InMemorySavedQueryRepository(queries: [savedQuery])
        let model = makeModel(profile: profile, repository: repository)
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        await model.connect()
        group.openSavedQuery(savedQuery.id)
        let item = try #require(group.tabsModel.selectedItem)
        let editorContext = item.editorContext

        try await model.deleteSavedQuery(savedQuery.id)

        #expect(model.savedQuery(id: savedQuery.id) == nil)
        #expect(try await repository.fetch(id: savedQuery.id) == nil)
        #expect(model.queryDocuments.first === item.document)
        #expect(item.document.savedQueryID == nil)
        #expect(item.document.sql == savedQuery.sql)
        #expect(item.document.databaseName == savedQuery.defaultDatabase)
        #expect(item.document.isDirty)
        #expect(item.document.canSave)
        #expect(group.tabsModel.selectedItem?.editorContext === editorContext)

        let replacement = try await model.saveQueryDocument(
            item.id,
            name: savedQuery.name
        )
        #expect(replacement.id != savedQuery.id)
        #expect(item.document.savedQueryID == replacement.id)
        #expect(!item.document.isDirty)
        #expect(group.tabsModel.selectedItem?.editorContext === editorContext)

        await model.disconnect()
    }

    @Test
    func renameAndMoveConflictsLeaveOriginalQueriesUnchanged() async throws {
        let profile = makeProfile()
        let original = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users"
        )
        let databaseConflict = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Existing"
        )
        let generalConflict = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: nil,
            name: "Recent Users"
        )
        let repository = InMemorySavedQueryRepository(
            queries: [original, databaseConflict, generalConflict]
        )
        let model = makeModel(profile: profile, repository: repository)
        await model.connect()

        await #expect(throws: SavedQueryRepositoryError.nameAlreadyExists) {
            try await model.renameSavedQuery(
                original.id,
                name: databaseConflict.name
            )
        }
        await #expect(throws: SavedQueryRepositoryError.nameAlreadyExists) {
            try await model.moveSavedQuery(original.id, to: nil)
        }

        #expect(model.savedQuery(id: original.id) == original)
        #expect(try await repository.fetch(id: original.id) == original)

        await model.disconnect()
    }

    @Test
    func concurrentSavedQueryMutationAndDocumentSaveAreRejected() async throws {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(
            profileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users"
        )
        let repository = SuspendedUpdateSavedQueryRepository(
            queries: [savedQuery]
        )
        let model = makeModel(profile: profile, repository: repository)
        await model.connect()
        let document = try #require(
            model.openSavedQueryDocument(savedQuery.id)?.document
        )
        document.sql = "SELECT 2;"

        let renameTask = Task {
            try await model.renameSavedQuery(
                savedQuery.id,
                name: "Active Users"
            )
        }
        await repository.waitUntilUpdateStarts()

        await #expect(throws: WorkspaceSavedQueryError.operationInProgress) {
            try await model.moveSavedQuery(savedQuery.id, to: nil)
        }
        await #expect(throws: WorkspaceSavedQueryError.operationInProgress) {
            try await model.saveQueryDocument(document.id)
        }

        await repository.finishUpdate()
        _ = try await renameTask.value

        await repository.suspendNextUpdate()
        let saveTask = Task {
            try await model.saveQueryDocument(document.id)
        }
        await repository.waitUntilUpdateStarts()

        await #expect(throws: WorkspaceSavedQueryError.saveInProgress) {
            try await model.renameSavedQuery(
                savedQuery.id,
                name: "Users"
            )
        }

        await repository.finishUpdate()
        _ = try await saveTask.value
        #expect(!document.isDirty)

        await model.disconnect()
    }

    @Test
    func commandSUsesTheEditorSaveHandler() {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "reader",
                password: nil,
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let languageService = WorkspaceSQLLanguageService()
        var saveCount = 0
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService,
            save: { saveCount += 1 }
        )
        let textView = TextView(string: "")

        #expect(
            coordinator.handleTextViewKeyCommand(
                .commandS,
                textView: textView
            )
        )
        #expect(saveCount == 1)
    }

    @Test
    func oneQueryProducesOneSelectedContentTab() {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1",
                port: 3306,
                username: "reader",
                password: nil,
                database: nil,
                tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let tabsModel = WorkspaceContentTabsModel()
        tabsModel.append(
            WorkspaceQueryTabItem(
                document: document,
                editorContext: WorkspaceQueryEditorContext(
                    document: document,
                    schemaCatalog: .empty,
                    prepareCompletionColumns: { _ in .empty }
                )
            )
        )
        #expect(tabsModel.contentItems.count == 1)
        #expect(tabsModel.selectedContentID == .queryDocument(document.id))
    }

    @Test
    func contentTabCloseActionsResolveStableTargets() {
        let tabsModel = WorkspaceContentTabsModel()
        let first = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let second = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "orders",
            kind: .table
        )
        let third = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "active_users",
            kind: .view
        )
        tabsModel.open(first)
        tabsModel.open(second)
        tabsModel.open(third)

        #expect(
            tabsModel.contentIDs(for: .closeOthers(.databaseObject(second)))
                == [.databaseObject(first), .databaseObject(third)]
        )
        #expect(
            tabsModel.contentIDs(for: .closeToRight(.databaseObject(first)))
                == [.databaseObject(second), .databaseObject(third)]
        )
        #expect(
            tabsModel.contentIDs(for: .closeToRight(.databaseObject(third)))
                .isEmpty
        )
        #expect(
            tabsModel.contentIDs(for: .closeAll)
                == [
                    .databaseObject(first),
                    .databaseObject(second),
                    .databaseObject(third),
                ]
        )
    }

    private func makeModel(
        profile: ConnectionProfile,
        savedQueries: [SavedQuery]
    ) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: InMemorySavedQueryRepository(
                queries: savedQueries
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app", "mysql"]
            )
        )
    }

    private func makeModel(
        profile: ConnectionProfile,
        repository: any SavedQueryRepository
    ) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: repository,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app", "mysql"]
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

    private func makeSavedQuery(
        profileID: ConnectionProfile.ID,
        defaultDatabase: String?,
        name: String,
        sql: String = "SELECT 1;"
    ) -> SavedQuery {
        SavedQuery(
            id: UUID(),
            connectionProfileID: profileID,
            defaultDatabase: defaultDatabase,
            name: name,
            sql: sql,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in rootView: NSView
    ) -> ViewType? {
        if let match = rootView as? ViewType {
            return match
        }
        for subview in rootView.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}

private actor SuspendedSavedQueryRepository: SavedQueryRepository {
    private var queries: [SavedQuery] = []
    private var insertContinuation: CheckedContinuation<Void, Never>?

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
        await withCheckedContinuation { continuation in
            insertContinuation = continuation
        }
        queries.append(query)
    }

    func update(_ query: SavedQuery) async throws {
        guard let index = queries.firstIndex(where: { $0.id == query.id })
        else {
            throw SavedQueryRepositoryError.queryNotFound
        }
        queries[index] = query
    }

    func delete(id: SavedQuery.ID) async throws {
        queries.removeAll { $0.id == id }
    }

    func waitUntilInsertStarts() async {
        while insertContinuation == nil {
            await Task.yield()
        }
    }

    func finishInsert() {
        insertContinuation?.resume()
        insertContinuation = nil
    }
}

private actor SuspendedUpdateSavedQueryRepository: SavedQueryRepository {
    private var queries: [SavedQuery]
    private var shouldSuspendNextUpdate = true
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
        if shouldSuspendNextUpdate {
            shouldSuspendNextUpdate = false
            await withCheckedContinuation { continuation in
                updateContinuation = continuation
            }
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

    func suspendNextUpdate() {
        shouldSuspendNextUpdate = true
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
