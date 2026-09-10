import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceWindowControllerTests {
    @Test
    func addingQueryTabsPreservesTheSingleWindowGeometryAndHost() async throws {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Window Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["app"])
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(x: 120, y: 120, width: 1_000, height: 700)
        )
        let window = try #require(controller.window)
        let contentController = try #require(window.contentViewController)
        let frame = window.frame
        defer {
            (window as? WorkspaceWindow)?.closeAfterApproval()
        }

        await model.connect()
        group.createQueryDocument()
        await Task.yield()
        group.createQueryDocument()
        await Task.yield()
        controller.replaceWorkspace()

        #expect(window.contentViewController === contentController)
        #expect(controller.rootViewInstallationCount == 1)
        #expect(window.frame == frame)
        #expect(window.tabbingMode == .disallowed)
        #expect(group.tabsModel.items.count == 2)
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        #expect(window.toolbar === controller.workspaceToolbar.managedToolbar)
        let navigationGroup = try #require(
            window.toolbar?.items.first(where: {
                $0.itemIdentifier == WorkspaceWindowToolbar.navigationGroup
            })
        )
        #expect(navigationGroup.view != nil)
        await model.disconnect()
    }

    @Test
    func openingSavedQueryPreservesWorkspaceHostAndReusesItsEditor() async throws {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Window Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        let savedQuery = SavedQuery(
            id: UUID(),
            connectionProfileID: profile.id,
            defaultDatabase: "app",
            name: "Recent Users",
            sql: "SELECT * FROM users;",
            createdAt: .now,
            updatedAt: .now
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: InMemorySavedQueryRepository(
                queries: [savedQuery]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
            )
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(
                x: 120,
                y: 120,
                width: 1_000,
                height: 700
            )
        )
        let window = try #require(controller.window)
        let contentController = try #require(window.contentViewController)
        let frame = window.frame
        defer {
            (window as? WorkspaceWindow)?.closeAfterApproval()
        }

        await model.connect()
        group.openSavedQuery(savedQuery.id)
        let firstItem = try #require(group.tabsModel.selectedItem)

        group.openSavedQuery(savedQuery.id)

        #expect(window.contentViewController === contentController)
        #expect(window.frame == frame)
        #expect(group.tabsModel.items.count == 1)
        #expect(group.tabsModel.selectedItem?.document === firstItem.document)
        #expect(
            group.tabsModel.selectedItem?.editorContext
                === firstItem.editorContext
        )
        await model.disconnect()
    }

    @Test
    func ordinaryQueryDetachesBeforeItsSessionCloses() async throws {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Window Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        let mainSession = InMemoryWorkspaceSession(databases: ["app"])
        let querySession = InMemoryWorkspaceSession(databases: ["app"])
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: WindowSessionSequenceFactory(
                sessions: [mainSession, querySession]
            )
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        await model.connect()
        let document = try #require(model.createQueryDocument())
        group.tabsModel.append(
            WorkspaceQueryTabItem(
                document: document,
                editorContext: WorkspaceQueryEditorContext(
                    document: document,
                    schemaCatalog: model.schemaCatalog,
                    prepareCompletionColumns: model.prepareCompletionColumns
                )
            )
        )
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: "SELECT 1"
        )
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: nil
        )
        await document.execute(target)
        #expect(await querySession.isConnected())

        let result = group.closeQueryDocumentInBackground(document.id)

        #expect(result == .closed)
        #expect(model.queryDocuments.isEmpty)
        #expect(group.tabsModel.items.isEmpty)
        await group.waitForPendingDocumentClosures()
        #expect(!(await querySession.isConnected()))
        await model.disconnect()
    }

    @Test
    func dirtyCloseAuthorizationKeepsTheWorkspaceAndRejectsLaterEdits()
        async throws
    {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Window Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
            )
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(
                x: 120,
                y: 120,
                width: 1_000,
                height: 700
            )
        )
        let window = try #require(controller.window)
        let contentController = try #require(window.contentViewController)
        let frame = window.frame
        defer {
            (window as? WorkspaceWindow)?.closeAfterApproval()
        }

        await model.connect()
        group.createQueryDocument()
        let item = try #require(group.tabsModel.selectedItem)
        item.document.sql = "SELECT 1;"

        #expect(
            group.closeQueryDocumentInBackground(item.id)
                == .needsUnsavedChangesDecision
        )
        #expect(model.queryDocuments.first === item.document)
        #expect(group.tabsModel.selectedItem?.editorContext === item.editorContext)
        #expect(window.contentViewController === contentController)
        #expect(window.frame == frame)

        let staleAuthorization =
            WorkspaceQueryDocumentCloseAuthorization
                .discardingCurrentChanges(in: item.document)
        item.document.sql = "SELECT 2;"

        #expect(
            group.closeQueryDocumentInBackground(
                item.id,
                authorization: staleAuthorization
            ) == .needsUnsavedChangesDecision
        )
        #expect(item.document.sql == "SELECT 2;")
        #expect(model.queryDocuments.first === item.document)
        #expect(group.tabsModel.selectedItem?.editorContext === item.editorContext)

        let currentAuthorization =
            WorkspaceQueryDocumentCloseAuthorization
                .discardingCurrentChanges(in: item.document)
        #expect(
            group.closeQueryDocumentInBackground(
                item.id,
                authorization: currentAuthorization
            ) == .closed
        )
        #expect(model.queryDocuments.isEmpty)
        #expect(group.tabsModel.items.isEmpty)
        #expect(window.contentViewController === contentController)
        #expect(window.frame == frame)

        await group.waitForPendingDocumentClosures()
        await model.disconnect()
    }

    @Test
    func closingSelectedInternalTabChoosesItsNextNeighbor() {
        let group = WorkspaceWindowGroup(
            profileID: UUID(),
            didClose: { _ in }
        )
        let configuration = DatabaseConnectionConfiguration(
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            password: nil,
            database: nil,
            tlsMode: .disabled
        )
        let factory = InMemoryWorkspaceSessionFactory(databases: [])
        let documents = (1...3).map {
            WorkspaceQueryDocumentModel(
                title: "Query \($0)",
                configuration: configuration,
                sessionFactory: factory
            )
        }
        for document in documents {
            group.tabsModel.append(
                WorkspaceQueryTabItem(
                    document: document,
                    editorContext: WorkspaceQueryEditorContext(
                        document: document,
                        schemaCatalog: .empty,
                        prepareCompletionColumns: { _ in .empty }
                    )
                )
            )
        }
        group.tabsModel.select(documents[1].id)

        let replacementID = group.tabsModel.remove(documents[1].id)

        #expect(replacementID == documents[2].id)
        #expect(group.tabsModel.items.map(\.id) == [
            documents[0].id,
            documents[2].id,
        ])
    }

    @Test
    func openingDatabaseObjectCreatesAndReusesAWorkspaceContentTab() {
        let group = WorkspaceWindowGroup(
            profileID: UUID(),
            didClose: { _ in }
        )
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )

        group.openDatabaseObject(selection)
        group.openDatabaseObject(selection)

        #expect(group.tabsModel.contentItems.count == 1)
        #expect(
            group.tabsModel.selectedContentID
                == .databaseObject(selection)
        )
    }

    @Test
    func closingLastQueryTabKeepsWorkspaceWindowOpen() async throws {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Window Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
            )
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let controller = WorkspaceWindowController(
            workspaceGroup: group,
            model: model,
            tabsModel: group.tabsModel,
            initialFrame: NSRect(
                x: 120,
                y: 120,
                width: 1_000,
                height: 700
            )
        )
        let window = try #require(controller.window)
        window.orderFront(nil)
        defer {
            (window as? WorkspaceWindow)?.closeAfterApproval()
        }

        await model.connect()
        group.createQueryDocument()

        controller.requestCloseSelectedContent()
        await group.waitForPendingDocumentClosures()
        await Task.yield()

        #expect(group.tabsModel.contentItems.isEmpty)
        #expect(window.isVisible)
        await model.disconnect()
    }

    @Test
    func contentHostSelectsOneQueryOrDatabaseObjectController() throws {
        let profileID = UUID()
        let model = WorkspaceModel(
            profileID: profileID,
            repository: InMemoryConnectionProfileRepository(),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let configuration = DatabaseConnectionConfiguration(
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            password: nil,
            database: nil,
            tlsMode: .disabled
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: configuration,
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let queryItem = WorkspaceQueryTabItem(
            document: document,
            editorContext: WorkspaceQueryEditorContext(
                document: document,
                schemaCatalog: .empty,
                prepareCompletionColumns: { _ in .empty }
            )
        )
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let controller = WorkspaceContentTabHostController()
        let contentRefreshRegistry = WorkspaceContentRefreshRegistry()
        let pendingChangesRegistry = WorkspacePendingChangesRegistry()
        let inspectorRegistry = WorkspaceInspectorRegistry()
        let objectDetailTabRegistry =
            WorkspaceDatabaseObjectDetailTabRegistry()
        let redisKeyActionRegistry = WorkspaceRedisKeyActionRegistry()
        let contentItems: [WorkspaceContentTabItem] = [
            .query(queryItem),
            .databaseObject(selection),
        ]

        controller.update(
            model: model,
            items: contentItems,
            contentRevision: 1,
            selectedContentID: .queryDocument(document.id),
            contentRefreshRegistry: contentRefreshRegistry,
            pendingChangesRegistry: pendingChangesRegistry,
            inspectorRegistry: inspectorRegistry,
            objectDetailTabRegistry: objectDetailTabRegistry,
            redisKeyActionRegistry: redisKeyActionRegistry
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let queryController = try #require(
            controller.contentController(
                for: .queryDocument(document.id)
            )
        )
        controller.update(
            model: model,
            items: contentItems,
            contentRevision: 1,
            selectedContentID: .databaseObject(selection),
            contentRefreshRegistry: contentRefreshRegistry,
            pendingChangesRegistry: pendingChangesRegistry,
            inspectorRegistry: inspectorRegistry,
            objectDetailTabRegistry: objectDetailTabRegistry,
            redisKeyActionRegistry: redisKeyActionRegistry
        )
        #expect(controller.contentReconciliationCount == 1)
        let databaseController = try #require(
            controller.contentController(for: .databaseObject(selection))
        )
        #expect(queryController.view.superview == nil)
        #expect(databaseController.view.superview === controller.view)
        controller.update(
            model: model,
            items: contentItems,
            contentRevision: 1,
            selectedContentID: .queryDocument(document.id),
            contentRefreshRegistry: contentRefreshRegistry,
            pendingChangesRegistry: pendingChangesRegistry,
            inspectorRegistry: inspectorRegistry,
            objectDetailTabRegistry: objectDetailTabRegistry,
            redisKeyActionRegistry: redisKeyActionRegistry
        )

        #expect(controller.contentControllerCount == 2)
        #expect(controller.contentReconciliationCount == 1)
        #expect(
            controller.selectedContentID == .queryDocument(document.id)
        )
        #expect(
            controller.contentController(
                for: .queryDocument(document.id)
            ) === queryController
        )
        #expect(queryController.view.superview === controller.view)
        #expect(databaseController.view.superview == nil)
        #expect(
            queryController.view.hitTest(
                NSPoint(
                    x: queryController.view.bounds.midX,
                    y: queryController.view.bounds.midY
                )
            ) != nil
        )
    }

    @Test
    func contentHostContainerSwapsRetainedDatabaseHostsInPlace() {
        let container = WorkspaceContentTabHostContainerController()
        let first = WorkspaceRetainedContentHostController()
        let second = WorkspaceRetainedContentHostController()
        container.loadViewIfNeeded()

        container.show(first, retaining: [first, second])
        let containerView = container.view
        #expect(container.contentHostController === first)
        #expect(first.parent === container)

        container.show(second, retaining: [first, second])

        #expect(container.view === containerView)
        #expect(container.contentHostController === second)
        #expect(first.parent === container)
        #expect(first.view.superview == nil)
        #expect(second.parent === container)
        #expect(second.view.superview === containerView)

        container.show(first, retaining: [first, second])

        #expect(container.view === containerView)
        #expect(container.contentHostController === first)
        #expect(first.parent === container)
        #expect(first.view.superview === containerView)
        #expect(second.parent === container)
        #expect(second.view.superview == nil)
    }

    @Test
    func initialConnectionFailureRetriesOnceAndRecovers() async throws {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Retry Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "reader",
            defaultDatabase: "app",
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        let factory = WindowSessionSequenceFactory(sessions: [
            UnavailableDatabaseWorkspaceSession(
                error: NSError(
                    domain: "WorkspaceWindowControllerTests",
                    code: 65
                )
            ),
            InMemoryWorkspaceSession(databases: ["app"]),
        ])
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: factory
        )
        let group = WorkspaceWindowGroup(
            model: model,
            automaticConnectionRetryDelay: .zero,
            didClose: { _ in }
        )

        group.open()
        for _ in 0..<100 where model.connectionState != .connected {
            await Task.yield()
        }

        #expect(model.connectionState == .connected)
        #expect(await factory.createdSessionCount == 2)
        #expect(await group.requestExplicitClose())
    }
}

private actor WindowSessionSequenceFactory: WorkspaceSessionFactory {
    private var sessions: [any WorkspaceSession]
    private(set) var createdSessionCount = 0

    init(sessions: [any WorkspaceSession]) {
        self.sessions = sessions
    }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        createdSessionCount += 1
        return sessions.removeFirst()
    }
}
