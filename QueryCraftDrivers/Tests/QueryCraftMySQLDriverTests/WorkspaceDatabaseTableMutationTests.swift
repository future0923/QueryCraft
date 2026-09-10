import Foundation
import Testing

@testable import QueryCraftFeature
@testable import QueryCraftMySQLDriver

struct WorkspaceDatabaseTableMutationTests {
    @Test
    func createTableUsesTheEditedColumnsAndIndexes() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()

        let idColumnID = editor.addColumn()
        var idDefinition = try #require(
            editor.columns.first(where: { $0.id == idColumnID })?.definition
        )
        idDefinition.name = "id"
        idDefinition.type = "BIGINT"
        idDefinition.isNullable = false
        idDefinition.defaultMode = .none
        idDefinition.isAutoIncrement = true
        editor.updateColumn(id: idColumnID, definition: idDefinition)
        editor.setPrimaryKey(columnID: idColumnID, isEnabled: true)

        let labelColumnID = editor.addColumn()
        var labelDefinition = try #require(
            editor.columns.first(where: { $0.id == labelColumnID })?.definition
        )
        labelDefinition.name = "label"
        labelDefinition.type = "VARCHAR(80)"
        labelDefinition.defaultMode = .value
        labelDefinition.defaultValue = "new"
        editor.updateColumn(id: labelColumnID, definition: labelDefinition)

        let mutation = WorkspaceDatabaseTableMutation.create(
            databaseName: "app`db",
            tableName: "order`items",
            columns: editor.columns,
            indexes: editor.indexes
        )
        let statement = MySQLWorkspaceSchemaStatement.make(
            tableMutation: mutation
        )

        #expect(
            statement.sql
                == "CREATE TABLE `app``db`.`order``items` (`id` BIGINT NOT NULL AUTO_INCREMENT, `label` VARCHAR(80) DEFAULT 'new', PRIMARY KEY (`id`) USING BTREE)"
        )
        #expect(
            statement.previewTokens.map(\.text).joined()
                == """
                CREATE TABLE `app``db`.`order``items` (
                    `id` BIGINT NOT NULL AUTO_INCREMENT,
                    `label` VARCHAR(80) DEFAULT 'new',
                    PRIMARY KEY (`id`) USING BTREE
                );
                """
        )
        #expect(mutation.statementKind == .ddl(.create))
        #expect(
            mutation.resultingSelection
                == WorkspaceDatabaseObjectSelection(
                    databaseName: "app`db",
                    objectName: "order`items",
                    kind: .table
                )
        )
    }

    @Test
    func createTableAppendsCommonAndAdvancedOptions() throws {
        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "id"
        definition.type = "BIGINT"
        definition.defaultMode = .none
        editor.updateColumn(id: columnID, definition: definition)
        let options = WorkspaceDatabaseTableOptions(
            engine: "InnoDB",
            characterSet: "utf8mb4",
            collation: "utf8mb4_0900_ai_ci",
            rowFormat: "DYNAMIC",
            autoIncrement: "100",
            comment: "owner's table",
            averageRowLength: "128",
            minimumRows: "10",
            maximumRows: "100000",
            keyBlockSize: "8"
        )

        let statement = MySQLWorkspaceSchemaStatement.make(
            tableMutation: .create(
                databaseName: "app",
                tableName: "users",
                columns: editor.columns,
                indexes: editor.indexes,
                options: options
            )
        )

        #expect(
            statement.sql
                == "CREATE TABLE `app`.`users` (`id` BIGINT) ENGINE=InnoDB DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci ROW_FORMAT=DYNAMIC AUTO_INCREMENT=100 COMMENT='owner''s table' AVG_ROW_LENGTH=128 MIN_ROWS=10 MAX_ROWS=100000 KEY_BLOCK_SIZE=8"
        )
        #expect(
            statement.previewTokens.map(\.text).joined()
                == """
                CREATE TABLE `app`.`users` (
                    `id` BIGINT
                )
                ENGINE=InnoDB
                DEFAULT CHARACTER SET=utf8mb4
                COLLATE=utf8mb4_0900_ai_ci
                ROW_FORMAT=DYNAMIC
                AUTO_INCREMENT=100
                COMMENT='owner''s table'
                AVG_ROW_LENGTH=128
                MIN_ROWS=10
                MAX_ROWS=100000
                KEY_BLOCK_SIZE=8;
                """
        )
    }

    @Test
    func renameAndDropTableQuoteIdentifiersAndPreserveSourceIdentity() {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app`db",
            objectName: "old`name",
            kind: .table
        )
        let rename = WorkspaceDatabaseTableMutation.rename(
            selection: selection,
            newName: "new`name"
        )
        let renameStatement = MySQLWorkspaceSchemaStatement.make(
            tableMutation: rename
        )
        let drop = WorkspaceDatabaseTableMutation.drop(selection: selection)
        let dropStatement = MySQLWorkspaceSchemaStatement.make(
            tableMutation: drop
        )

        #expect(
            renameStatement.sql
                == "RENAME TABLE `app``db`.`old``name` TO `app``db`.`new``name`"
        )
        #expect(
            dropStatement.sql == "DROP TABLE `app``db`.`old``name`"
        )
        #expect(rename.sourceSelection == selection)
        #expect(rename.statementKind == .ddl(.alter))
        #expect(drop.sourceSelection == selection)
        #expect(drop.resultingSelection == nil)
        #expect(drop.statementKind == .ddl(.drop))
    }

    @MainActor
    @Test
    func renamingAnOpenTableReplacesItsStableTabIdentity() {
        let tabs = WorkspaceContentTabsModel()
        let oldSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let newSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "members",
            kind: .table
        )
        let otherSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "orders",
            kind: .table
        )
        tabs.open(oldSelection)
        tabs.open(otherSelection)
        tabs.select(.databaseObject(oldSelection))

        tabs.replaceDatabaseObject(oldSelection, with: newSelection)

        #expect(
            tabs.contentItems.map(\.id)
                == [
                    .databaseObject(newSelection),
                    .databaseObject(otherSelection),
                ]
        )
        #expect(tabs.selectedContentID == .databaseObject(newSelection))
    }

    @MainActor
    @Test
    func renamingToAnAlreadyOpenTableDoesNotDuplicateTheTab() {
        let tabs = WorkspaceContentTabsModel()
        let oldSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let newSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "members",
            kind: .table
        )
        tabs.open(oldSelection)
        tabs.open(newSelection)
        tabs.select(.databaseObject(oldSelection))

        tabs.replaceDatabaseObject(oldSelection, with: newSelection)

        #expect(tabs.contentItems.map(\.id) == [.databaseObject(newSelection)])
        #expect(tabs.selectedContentID == .databaseObject(newSelection))
    }

    @MainActor
    @Test
    func newTableDraftOffersStructureIndexesAndOptions() {
        let draft = WorkspaceNewTableDraft(databaseName: "app")

        #expect(
            draft.availableTabs
                == [.structure, .indexes, .options]
        )
        #expect(draft.selectedTab == .structure)
        #expect(draft.editor.columns.count == 1)
        #expect(draft.editor.indexes.isEmpty)
    }

    @MainActor
    @Test
    func newTableOptionsLinkCharacterMetadataAndResetWithDraft() {
        let choices = WorkspaceDatabaseSchemaChoices(
            engines: ["InnoDB"],
            characterSets: ["utf8mb4", "latin1"],
            collations: [
                .init(
                    name: "utf8mb4_0900_ai_ci",
                    characterSet: "utf8mb4",
                    isDefault: true
                ),
                .init(
                    name: "latin1_swedish_ci",
                    characterSet: "latin1",
                    isDefault: true
                ),
            ]
        )
        var options = WorkspaceDatabaseTableOptions()
        options.applyCharacterSet("utf8mb4", choices: choices)
        #expect(options.collation == "utf8mb4_0900_ai_ci")
        options.applyCollation("latin1_swedish_ci", choices: choices)
        #expect(options.characterSet == "latin1")

        let draft = WorkspaceNewTableDraft(databaseName: "app")
        draft.editor.updateSchemaChoices(choices)
        draft.options = options
        draft.options.maximumRows = "1000"
        draft.selectedTab = .options

        draft.reset()

        #expect(draft.options == WorkspaceDatabaseTableOptions())
        #expect(draft.editor.schemaChoices == choices)
        #expect(draft.selectedTab == .structure)
    }

    @MainActor
    @Test
    func createdTableReplacesItsDraftAtTheSameTabPosition() {
        let tabs = WorkspaceContentTabsModel()
        let firstSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )
        let createdSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "orders",
            kind: .table
        )
        let draft = WorkspaceNewTableDraft(databaseName: "app")
        tabs.open(firstSelection)
        tabs.append(draft)

        tabs.replaceNewTable(draft.id, with: createdSelection)

        #expect(
            tabs.contentItems.map(\.id)
                == [
                    .databaseObject(firstSelection),
                    .databaseObject(createdSelection),
                ]
        )
        #expect(tabs.selectedContentID == .databaseObject(createdSelection))
    }

    @MainActor
    @Test
    func restorationIgnoresTransientNewTableDrafts() {
        let tabs = WorkspaceContentTabsModel()
        let draftID = UUID()
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )

        tabs.restore(
            queryItems: [],
            contentOrder: [.newTable(draftID), .databaseObject(selection)],
            selecting: .newTable(draftID)
        )

        #expect(tabs.contentItems.map(\.id) == [.databaseObject(selection)])
        #expect(tabs.selectedContentID == .databaseObject(selection))
    }

    @MainActor
    @Test
    func safetyLockBlocksTableDDLBeforeOpeningAChangeSession() async {
        let profile = makeProfile()
        let store = TableMutationTestStore(objects: [])
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: TableMutationTestSessionFactory(store: store)
        )
        let mutation = WorkspaceDatabaseTableMutation.create(
            databaseName: "app",
            tableName: "users",
            columns: [],
            indexes: []
        )

        await #expect(
            throws: WorkspaceDatabaseTableMutationError.safetyLockEnabled
        ) {
            try await model.applyTableMutation(mutation)
        }
        #expect(await store.connectionCount == 0)
    }

    @MainActor
    @Test
    func successfulTableDDLRefreshesTheAuthoritativeObjectList() async throws {
        let profile = makeProfile()
        let store = TableMutationTestStore(
            objects: [WorkspaceDatabaseObject(name: "users", kind: .table)]
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: TableMutationTestSessionFactory(store: store)
        )
        await model.connect()
        await model.loadObjects(in: "app")
        model.safetyLock.disable()

        var editor = WorkspaceDatabaseSchemaEditorState()
        let columnID = editor.addColumn()
        var definition = try #require(editor.columns.first?.definition)
        definition.name = "id"
        definition.type = "BIGINT"
        definition.isNullable = false
        definition.defaultMode = .none
        editor.updateColumn(id: columnID, definition: definition)
        let mutation = WorkspaceDatabaseTableMutation.create(
            databaseName: "app",
            tableName: "orders",
            columns: editor.columns,
            indexes: editor.indexes
        )
        await store.setObjectsAfterMutation([
            WorkspaceDatabaseObject(name: "users", kind: .table),
            WorkspaceDatabaseObject(name: "orders", kind: .table),
        ])

        try await model.applyTableMutation(mutation)

        let database = try #require(model.currentDatabase)
        guard case let .loaded(objects) = database.objectsState else {
            Issue.record("Expected the refreshed object list to be loaded")
            return
        }
        #expect(objects.map(\.name) == ["users", "orders"])
        #expect(
            await store.executedSQL
                == ["CREATE TABLE `app`.`orders` (`id` BIGINT NOT NULL)"]
        )
        #expect(await store.objectFetchCount == 2)
    }

    private func makeProfile() -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "Local MySQL",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            defaultDatabase: "app",
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
    }
}

private actor TableMutationTestStore {
    private(set) var connectionCount = 0
    private(set) var objectFetchCount = 0
    private(set) var executedSQL: [String] = []
    private var objects: [WorkspaceDatabaseObject]
    private var objectsAfterMutation: [WorkspaceDatabaseObject]?

    init(objects: [WorkspaceDatabaseObject]) {
        self.objects = objects
    }

    func connected() {
        connectionCount += 1
    }

    func fetchObjects() -> [WorkspaceDatabaseObject] {
        objectFetchCount += 1
        return objects
    }

    func setObjectsAfterMutation(_ objects: [WorkspaceDatabaseObject]) {
        objectsAfterMutation = objects
    }

    func execute(_ sql: String) {
        executedSQL.append(sql)
        if let objectsAfterMutation {
            objects = objectsAfterMutation
            self.objectsAfterMutation = nil
        }
    }
}

private struct TableMutationTestSessionFactory: WorkspaceSessionFactory {
    let store: TableMutationTestStore

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        TableMutationTestSession(store: store)
    }
}

private actor TableMutationTestSession: WorkspaceSession {
    let store: TableMutationTestStore
    private var connected = false

    init(store: TableMutationTestStore) {
        self.store = store
    }

    func connect() async throws {
        connected = true
        await store.connected()
    }

    func isConnected() -> Bool {
        connected
    }

    func fetchDatabases() throws -> [String] {
        ["app"]
    }

    func schemaEditingProvider() -> (any DatabaseSchemaEditingProvider)? {
        MySQLSchemaEditingProvider()
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        await store.fetchObjects()
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw WorkspaceSessionError.metadataUnavailable(object: object.name)
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        []
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
        WorkspaceDatabaseDataFetchResult(
            columns: [],
            hasNextPage: false
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        0
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        onBatch: @escaping @Sendable (
            WorkspaceDatabaseDataBatch
        ) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        await store.execute(sql)
        return WorkspaceQueryExecutionResult(columns: [], rowCount: 0)
    }

    func applySchemaExecutionPlan(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws {
        for statement in plan.statements {
            await store.execute(statement.sql)
        }
    }

    func close() {
        connected = false
    }
}
