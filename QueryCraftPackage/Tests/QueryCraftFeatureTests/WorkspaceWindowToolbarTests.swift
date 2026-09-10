import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceWindowToolbarTests {
    @Test
    func navigationGroupIsTrailingAlignedInsideSidebarSection() throws {
        let identifiers = WorkspaceWindowToolbar.defaultItemIdentifiers
        let groupIndex = try #require(
            identifiers.firstIndex(of: WorkspaceWindowToolbar.navigationGroup)
        )
        let separatorIndex = try #require(
            identifiers.firstIndex(of: .sidebarTrackingSeparator)
        )

        #expect(groupIndex > identifiers.startIndex)
        #expect(identifiers[groupIndex - 1] == .flexibleSpace)
        #expect(groupIndex + 1 == separatorIndex)
    }

    @Test
    func standardTrackingSeparatorIsLeftToAppKit() throws {
        let toolbar = makeToolbar()

        #expect(
            toolbar.toolbar(
                toolbar.managedToolbar,
                itemForItemIdentifier: .sidebarTrackingSeparator,
                willBeInsertedIntoToolbar: true
            ) == nil
        )
    }

    @Test
    func connectionIdentityKeepsItsCenteredToolbarPosition() {
        let toolbar = makeToolbar()

        #expect(
            toolbar.managedToolbar.centeredItemIdentifiers
                == [WorkspaceWindowToolbar.connectionIdentity]
        )
    }

    @Test
    func elasticsearchDoesNotOfferDatabaseSelection() async {
        let toolbarModel = makeToolbarModel(databaseProduct: .elasticsearch)

        _ = await toolbarModel.model.connect()

        #expect(!toolbarModel.showsDatabaseSelection)
    }

    @Test
    func previewActionsOpenTheSharedSQLPreviewPresentation() {
        let toolbarModel = makeToolbarModel()
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let contentID = WorkspaceContentTabID.databaseObject(selection)
        toolbarModel.presentation.context.tabsModel.open(selection)
        toolbarModel.presentation.context.pendingChangesRegistry.update(
            WorkspacePendingChangesActions(
                hasChanges: true,
                statements: [previewStatement],
                isCommitting: false,
                discard: {},
                preview: {},
                commit: {}
            ),
            for: contentID
        )

        toolbarModel.previewPendingChanges()
        #expect(toolbarModel.showsSQLPreview)

        toolbarModel.closeSQLPreview()
        toolbarModel.focusedPendingChangesActions?.preview()
        #expect(toolbarModel.showsSQLPreview)
    }

    @Test
    func conflictedElasticsearchChangeDisablesCommitButKeepsPreview() async {
        let toolbarModel = makeToolbarModel(databaseProduct: .elasticsearch)
        _ = await toolbarModel.model.connect()
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "Elasticsearch",
            objectName: "logs",
            kind: .elasticsearchIndex
        )
        let contentID = WorkspaceContentTabID.databaseObject(selection)
        toolbarModel.presentation.context.tabsModel.open(selection)
        toolbarModel.presentation.context.pendingChangesRegistry.update(
            WorkspacePendingChangesActions(
                hasChanges: true,
                elasticsearchRequests: [
                    WorkspaceRequest(
                        method: .delete,
                        path: "/logs/_doc/1"
                    ),
                ],
                canCommit: false,
                isCommitting: false,
                discard: {},
                preview: {},
                commit: {}
            ),
            for: contentID
        )

        #expect(toolbarModel.canPreviewPendingChanges)
        #expect(!toolbarModel.canCommitPendingChanges)
        #expect(toolbarModel.canDiscardPendingChanges)
    }

    @Test
    func redisKeyUsesTheToolbarContextualRefreshAction() async {
        var workspaceRefreshCount = 0
        var keyRefreshCount = 0
        let toolbarModel = makeToolbarModel {
            workspaceRefreshCount += 1
        }
        _ = await toolbarModel.model.connect()
        let reference = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:test",
            type: .hash
        )
        let contentID = WorkspaceContentTabID.redisKey(reference)
        toolbarModel.presentation.context.tabsModel.open(reference)
        toolbarModel.presentation.context.contentRefreshRegistry.update(
            WorkspaceContentRefreshActions(
                title: "Refresh Key",
                isStopping: false,
                didComplete: false,
                perform: { keyRefreshCount += 1 }
            ),
            for: contentID
        )

        #expect(toolbarModel.refreshActionTitle == "Refresh Key")
        #expect(!toolbarModel.isRefreshActionDisabled)
        toolbarModel.performRefreshAction()
        #expect(keyRefreshCount == 1)
        #expect(workspaceRefreshCount == 0)
    }

    private func makeToolbar() -> WorkspaceWindowToolbar {
        WorkspaceWindowToolbar(model: makeToolbarModel())
    }

    private func makeToolbarModel(
        databaseProduct: DatabaseProduct = .mysql,
        refreshWorkspace: @escaping @MainActor () -> Void = {}
    ) -> WorkspaceToolbarModel {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Toolbar Test",
            groupID: nil,
            databaseProduct: databaseProduct,
            host: "127.0.0.1",
            port: databaseProduct == .elasticsearch ? 9200 : 3306,
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
                databases: databaseProduct == .elasticsearch
                    ? ["Elasticsearch"]
                    : ["app"]
            )
        )
        let group = WorkspaceWindowGroup(model: model, didClose: { _ in })
        let presentation = WorkspaceWindowPresentation(
            context: group.activeDatabaseContext,
            retainedContexts: group.databaseContexts,
            databaseContexts: group.databaseContextDescriptors,
            selectedDatabaseContextID: group.selectedContextID
        )
        return WorkspaceToolbarModel(
            presentation: presentation,
            createQueryDocument: {},
            refreshWorkspace: refreshWorkspace
        )
    }

    private var previewStatement: WorkspaceSQLPreviewStatement {
        WorkspaceSQLPreviewStatement(
            tokens: [
                WorkspaceSQLPreviewToken(text: "UPDATE", kind: .keyword),
            ]
        )
    }
}
