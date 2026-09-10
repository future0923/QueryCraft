import AppKit
import CodeEditTextView
import Observation
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite(.serialized)
struct WorkspaceRestorationTests {
    @Test
    func restoresDocumentsSelectionAndObjectWithoutRuntimeState()
        async throws
    {
        let profile = makeProfile()
        let savedQuery = makeSavedQuery(profileID: profile.id)
        let savedDocumentID = UUID()
        let draftDocumentID = UUID()
        let blankDocumentID = UUID()
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let restoredDataPage = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "id")],
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("1")])
            ],
            offset: 0,
            limit: 1,
            hasNextPage: false
        )
        let restoredDetails = WorkspaceDatabaseObjectDetails(
            columns: [
                WorkspaceDatabaseColumn(
                    name: "id",
                    type: "bigint",
                    collation: nil,
                    isNullable: false,
                    key: "PRI",
                    defaultValue: nil,
                    extra: "auto_increment",
                    comment: ""
                )
            ],
            ddl: "CREATE TABLE `users` (`id` bigint NOT NULL)",
            tableInformation: WorkspaceDatabaseTableInformation(
                dataSize: 16_384,
                indexSize: 16_384,
                comment: "Restored users",
                engine: "InnoDB"
            )
        )
        let contextID = UUID()
        let restoredDocuments = [
            WorkspaceQueryDocumentRestorationState(
                id: savedDocumentID,
                title: savedQuery.name,
                savedQueryID: savedQuery.id,
                defaultDatabase: savedQuery.defaultDatabase,
                resultRowLimit: .rows5_000
            ),
            WorkspaceQueryDocumentRestorationState(
                id: draftDocumentID,
                title: "Work in Progress",
                savedQueryID: savedQuery.id,
                defaultDatabase: "app",
                resultRowLimit: .unlimited
            ),
            WorkspaceQueryDocumentRestorationState(
                id: blankDocumentID,
                title: "Query 3",
                savedQueryID: nil,
                defaultDatabase: "archive",
                resultRowLimit: .rows100
            ),
        ]
        let contentTabOrder: [WorkspaceContentTabID] = [
            .queryDocument(savedDocumentID),
            .databaseObject(selection),
            .queryDocument(draftDocumentID),
            .queryDocument(blankDocumentID),
        ]
        let context = WorkspaceDatabaseContextRestorationState(
            id: contextID,
            databaseName: "app",
            selectedObject: selection,
            queryDocuments: restoredDocuments,
            selectedQueryDocumentID: draftDocumentID,
            contentTabOrder: contentTabOrder,
            selectedContentTab: .databaseObject(selection),
            sidebarMode: .items
        )
        let state = WorkspaceRestorationState(
            id: UUID(),
            connectionProfileID: profile.id,
            databaseContexts: [context],
            selectedDatabaseContextID: contextID,
            windowFrame: WorkspaceWindowFrame(
                x: 80,
                y: 100,
                width: 1_100,
                height: 760
            ),
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_100)
        )
        let draft = RecoverableDraft(
            id: draftDocumentID,
            workspaceID: state.id,
            connectionProfileID: profile.id,
            defaultDatabase: "app",
            sql: "SELECT * FROM users WHERE active = TRUE;",
            createdAt: Date(timeIntervalSince1970: 1_050),
            updatedAt: Date(timeIntervalSince1970: 1_060)
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            workspaceID: state.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            savedQueryRepository: InMemorySavedQueryRepository(
                queries: [savedQuery]
            ),
            recoverableDraftRepository: InMemoryRecoverableDraftRepository(
                drafts: [draft]
            ),
            restorationState: state,
            recoverableDraftSaveDelay: .zero,
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app", "archive"],
                objectsByDatabase: [
                    "app": [
                        WorkspaceDatabaseObject(name: "users", kind: .table)
                    ]
                ],
                detailsByObject: [selection: restoredDetails],
                dataByObject: [selection: restoredDataPage]
            )
        )
        let group = WorkspaceWindowGroup(
            model: model,
            restorationRepository: InMemoryWorkspaceRestorationRepository(
                states: [state]
            ),
            didClose: { _ in }
        )

        await model.connect {
            await group.restoreRecoveredQueryDocuments()
        }
        await group.restoreRecoveredQueryDocuments()

        #expect(model.workspaceID == state.id)
        #expect(model.queryDocuments.map(\.id) == [
            savedDocumentID,
            draftDocumentID,
            blankDocumentID,
        ])
        #expect(group.tabsModel.items.map(\.id) == [
            savedDocumentID,
            draftDocumentID,
            blankDocumentID,
        ])
        #expect(group.tabsModel.contentItems.map(\.id) == [
            .queryDocument(savedDocumentID),
            .databaseObject(selection),
            .queryDocument(draftDocumentID),
            .queryDocument(blankDocumentID),
        ])
        #expect(
            group.tabsModel.selectedContentID == .databaseObject(selection)
        )
        #expect(group.tabsModel.selectedDocumentID == nil)
        #expect(model.selectedObject == selection)
        #expect(model.selectedQueryDocumentID == nil)
        guard case let .loaded(restoredPage) = model.selectedObjectDataState
        else {
            Issue.record("Restored Table Data did not finish its initial load")
            await model.disconnect()
            return
        }
        #expect(restoredPage.rows == restoredDataPage.rows)
        #expect(model.selectedObjectDetailsState == .loaded(restoredDetails))

        let savedDocument = try #require(model.queryDocuments.first)
        #expect(savedDocument.savedQueryID == savedQuery.id)
        #expect(savedDocument.sql == savedQuery.sql)
        #expect(!savedDocument.isDirty)
        #expect(savedDocument.resultRowLimit == .rows5_000)

        let draftDocument = model.queryDocuments[1]
        #expect(draftDocument.savedQueryID == nil)
        #expect(draftDocument.title == "Work in Progress")
        #expect(draftDocument.sql == draft.sql)
        #expect(draftDocument.resultRowLimit == .unlimited)
        #expect(model.queryDocuments[2].resultRowLimit == .rows100)
        #expect(draftDocument.isDirty)

        let blankDocument = try #require(model.queryDocuments.last)
        #expect(blankDocument.databaseName == "archive")
        #expect(!blankDocument.isDirty)

        for document in model.queryDocuments {
            #expect(document.executionState == .idle)
            #expect(document.statementResults.isEmpty)
            #expect(document.transactionState == .disconnected)
        }

        await model.disconnect()
    }

    @Test
    func explicitWorkspaceCloseDeletesItsRestorationState() async throws {
        let profile = makeProfile()
        let repository = InMemoryWorkspaceRestorationRepository()
        let model = makeModel(profile: profile)
        let group = WorkspaceWindowGroup(
            model: model,
            restorationRepository: repository,
            didClose: { _ in }
        )
        await openAndWaitUntilConnected(group, model: model)
        group.createQueryDocument()
        let documentID = try #require(group.tabsModel.selectedDocumentID)
        group.windowFrameDidChange(
            NSRect(x: 90, y: 110, width: 1_040, height: 700),
            immediately: true
        )
        await group.waitForRestorationPersistence()

        let persisted = try #require(
            try await repository.fetch(id: model.workspaceID)
        )
        #expect(
            persisted.selectedDatabaseContext.queryDocuments.map(\.id)
                == [documentID]
        )
        #expect(
            persisted.selectedDatabaseContext.selectedQueryDocumentID
                == documentID
        )
        #expect(persisted.windowFrame?.width == 1_040)

        let window = try #require(group.activeWindow as? WorkspaceWindow)
        let closeButton = try #require(
            window.standardWindowButton(.closeButton)
        )
        await closeAndWait(for: window) {
            closeButton.performClick(nil)
        }
        await group.waitForRestorationPersistence()

        #expect(try await repository.fetch(id: model.workspaceID) == nil)
    }

    @Test
    func explicitWorkspaceCloseWaitsForRestorationDeletionBeforeClosingWindow()
        async throws
    {
        let profile = makeProfile()
        let repository = SuspendedDeletionWorkspaceRestorationRepository()
        let model = makeModel(profile: profile)
        let group = WorkspaceWindowGroup(
            model: model,
            restorationRepository: repository,
            didClose: { _ in }
        )
        await openAndWaitUntilConnected(group, model: model)
        await group.waitForRestorationPersistence()

        let window = try #require(group.activeWindow as? WorkspaceWindow)
        let closeNotification = Task { @MainActor in
            for await notification in NotificationCenter.default
                .notifications(named: NSWindow.willCloseNotification)
            {
                guard let closedWindow = notification.object as? NSWindow,
                      closedWindow === window
                else {
                    continue
                }
                return
            }
        }
        await Task.yield()

        window.performClose(nil)
        await repository.waitUntilDeleteStarts()

        #expect(window.isVisible)

        await repository.finishDelete()
        await closeNotification.value

        #expect(!window.isVisible)
        #expect(try await repository.fetch(id: model.workspaceID) == nil)
    }

    @Test
    func redCloseButtonPromptsForDirtyQueryAndCancelKeepsWorkspaceOpen()
        async throws
    {
        let profile = makeProfile()
        let repository = InMemoryWorkspaceRestorationRepository()
        let model = makeModel(profile: profile)
        let group = WorkspaceWindowGroup(
            model: model,
            restorationRepository: repository,
            didClose: { _ in }
        )
        await openAndWaitUntilConnected(group, model: model)
        group.createQueryDocument()
        let document = try #require(group.tabsModel.selectedItem?.document)
        let window = try #require(group.activeWindow as? WorkspaceWindow)
        window.contentView?.layoutSubtreeIfNeeded()
        let textView = try #require(findCodeEditTextView(in: window.contentView))
        try #require(window.makeFirstResponder(textView))
        textView.string = "SELECT * FROM users;"

        #expect(document.sql.isEmpty)
        #expect(!document.isDirty)
        await group.waitForRestorationPersistence()

        let closeButton = try #require(
            window.standardWindowButton(.closeButton)
        )
        closeButton.performClick(nil)

        let sheet = try #require(await waitForAttachedSheet(on: window))
        #expect(document.sql == "SELECT * FROM users;")
        #expect(document.isDirty)
        let promptText = descendantText(in: sheet.contentView)
        #expect(window.isVisible)
        #expect(promptText.contains { $0.contains(document.title) })
        #expect(promptText.contains("保存") || promptText.contains("Save"))
        #expect(promptText.contains("不保存") || promptText.contains("Don't Save"))
        let dontSaveButton = try #require(
            descendantButtons(in: sheet.contentView).first {
                $0.title == "不保存" || $0.title == "Don't Save"
            }
        )
        #expect(!dontSaveButton.hasDestructiveAction)

        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await Task.yield()
        await Task.yield()

        #expect(window.isVisible)
        #expect(document.isDirty)
        #expect(try await repository.fetch(id: model.workspaceID) != nil)

        await closeAndWait(for: window) {
            window.closeAfterApproval()
        }
    }

    @Test
    func nonExplicitWindowDestructionPreservesRestorationState() async throws {
        let profile = makeProfile()
        let repository = InMemoryWorkspaceRestorationRepository()
        let model = makeModel(profile: profile)
        let group = WorkspaceWindowGroup(
            model: model,
            restorationRepository: repository,
            didClose: { _ in }
        )
        await openAndWaitUntilConnected(group, model: model)
        group.createQueryDocument()
        let documentID = try #require(group.tabsModel.selectedDocumentID)
        await group.waitForRestorationPersistence()

        let window = try #require(group.activeWindow as? WorkspaceWindow)
        await closeAndWait(for: window) {
            window.closeAfterApproval()
        }
        await group.waitForRestorationPersistence()

        let persisted = try #require(
            try await repository.fetch(id: model.workspaceID)
        )
        #expect(
            persisted.selectedDatabaseContext.queryDocuments.map(\.id)
                == [documentID]
        )
    }

    private func openAndWaitUntilConnected(
        _ group: WorkspaceWindowGroup,
        model: WorkspaceModel
    ) async {
        await withCheckedContinuation { continuation in
            observeConnection(model, continuation: continuation)
            group.open()
        }
    }

    private func observeConnection(
        _ model: WorkspaceModel,
        continuation: CheckedContinuation<Void, Never>
    ) {
        switch model.connectionState {
        case .connected:
            continuation.resume()
        case let .failed(message):
            Issue.record("Workspace connection failed: \(message)")
            continuation.resume()
        case .connecting:
            withObservationTracking {
                _ = model.connectionState
            } onChange: {
                Task { @MainActor in
                    self.observeConnection(
                        model,
                        continuation: continuation
                    )
                }
            }
        }
    }

    private func closeAndWait(
        for window: NSWindow,
        action: @escaping @MainActor () -> Void
    ) async {
        await confirmation("Workspace window closes") { confirmed in
            let notificationTask = Task { @MainActor in
                for await notification in NotificationCenter.default
                    .notifications(named: NSWindow.willCloseNotification)
                {
                    guard let closedWindow = notification.object as? NSWindow,
                          closedWindow === window
                    else {
                        continue
                    }
                    confirmed()
                    break
                }
            }
            await Task.yield()
            action()
            await notificationTask.value
        }
    }

    private func waitForAttachedSheet(on window: NSWindow) async -> NSWindow? {
        for _ in 0..<100 {
            if let attachedSheet = window.attachedSheet {
                return attachedSheet
            }
            await Task.yield()
        }
        return nil
    }

    private func descendantText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        var text: [String] = []
        if let field = view as? NSTextField {
            text.append(field.stringValue)
        }
        if let button = view as? NSButton {
            text.append(button.title)
        }
        return text + view.subviews.flatMap(descendantText(in:))
    }

    private func descendantButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        let button = (view as? NSButton).map { [$0] } ?? []
        return button + view.subviews.flatMap(descendantButtons(in:))
    }

    private func findCodeEditTextView(in view: NSView?) -> TextView? {
        guard let view else { return nil }
        if let textView = view as? TextView { return textView }
        return view.subviews.lazy.compactMap(findCodeEditTextView(in:)).first
    }

    private func makeModel(profile: ConnectionProfile) -> WorkspaceModel {
        WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app"]
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
}

private actor SuspendedDeletionWorkspaceRestorationRepository:
    WorkspaceRestorationRepository
{
    private var states: [WorkspaceRestorationState] = []
    private var deleteStarted = false
    private var deleteContinuation: CheckedContinuation<Void, Never>?

    func fetchAll() async throws -> [WorkspaceRestorationState] {
        states
    }

    func fetch(id: WorkspaceRestorationState.ID) async throws
        -> WorkspaceRestorationState?
    {
        states.first { $0.id == id }
    }

    func save(_ state: WorkspaceRestorationState) async throws {
        states.removeAll { $0.id == state.id }
        states.append(state)
    }

    func delete(id: WorkspaceRestorationState.ID) async throws {
        deleteStarted = true
        await withCheckedContinuation { continuation in
            deleteContinuation = continuation
        }
        states.removeAll { $0.id == id }
    }

    func waitUntilDeleteStarts() async {
        while !deleteStarted {
            await Task.yield()
        }
    }

    func finishDelete() {
        deleteContinuation?.resume()
        deleteContinuation = nil
    }
}
