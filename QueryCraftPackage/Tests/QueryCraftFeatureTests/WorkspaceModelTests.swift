import Foundation
import Observation
import Synchronization
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceModelTests {
    @Test
    func elasticsearchAutomaticallyUsesItsImplicitWorkspaceContext() async {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Local Elasticsearch",
            groupID: nil,
            databaseProduct: .elasticsearch,
            host: "127.0.0.1",
            port: 9200,
            username: "elastic",
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
                databases: ["Elasticsearch"]
            )
        )

        _ = await model.connect()

        #expect(model.databaseContextName == "Elasticsearch")
        #expect(model.currentDatabase?.name == "Elasticsearch")
    }

    @Test
    func queryResultDetailsUseDocumentConnectionWhenWorkspaceIsUnavailable()
        async throws
    {
        let profile = makeProfile(storesCredential: false)
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "querycraft_test",
            objectName: "qc_insert_paste_semantics",
            kind: .table
        )
        let details = WorkspaceDatabaseObjectDetails(
            columns: [
                WorkspaceDatabaseColumn(
                    name: "id",
                    type: "bigint",
                    collation: nil,
                    isNullable: false,
                    key: "PRI",
                    defaultValue: nil,
                    extra: "",
                    comment: ""
                )
            ],
            ddl: "CREATE TABLE `qc_insert_paste_semantics` (`id` bigint PRIMARY KEY)"
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["querycraft_test"],
                objectsByDatabase: [
                    "querycraft_test": [
                        WorkspaceDatabaseObject(
                            name: "qc_insert_paste_semantics",
                            kind: .table
                        )
                    ]
                ],
                detailsByObject: [selection: details]
            )
        )
        let configuration = DatabaseConnectionConfiguration(
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            password: nil,
            database: "querycraft_test",
            tlsMode: .disabled
        )

        #expect(model.connectionState != .connected)
        let loadedDetails = try await model.fetchQueryResultDetails(
            for: selection,
            configuration: configuration
        )

        #expect(loadedDetails == details)
        #expect(model.connectionState != .connected)
    }

    @Test
    func connectsLoadsDatabasesAndLazilyLoadsObjects() async throws {
        let profile = makeProfile(storesCredential: true)
        let usersSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        )
        let usersDetails = WorkspaceDatabaseObjectDetails(
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
            ddl: "CREATE TABLE `users` (`id` bigint NOT NULL)"
        )
        let usersData = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("1"), .text("Alice")]
                ),
                WorkspaceDatabaseDataRow(
                    id: 1,
                    values: [.text("2"), .text("Bob")]
                ),
            ],
            offset: 0,
            limit: WorkspaceDatabaseDataPage.defaultLimit,
            hasNextPage: false
        )
        let usersIndexes = [
            WorkspaceDatabaseIndex(
                name: "PRIMARY",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "id",
                        prefixLength: nil,
                        direction: "A",
                        isExpression: false
                    )
                ],
                isUnique: true,
                type: "BTREE",
                cardinality: 2,
                isVisible: true,
                comment: ""
            ),
            WorkspaceDatabaseIndex(
                name: "idx_users_name_created",
                columns: [
                    WorkspaceDatabaseIndexColumn(
                        sequence: 1,
                        name: "name",
                        prefixLength: 40,
                        direction: "A",
                        isExpression: false
                    ),
                    WorkspaceDatabaseIndexColumn(
                        sequence: 2,
                        name: "created_at",
                        prefixLength: nil,
                        direction: "D",
                        isExpression: false
                    ),
                ],
                isUnique: false,
                type: "BTREE",
                cardinality: 2,
                isVisible: true,
                comment: ""
            ),
        ]
        let sessionFactory = InMemoryWorkspaceSessionFactory(
            databases: [
                "mysql",
                "app_database",
                "analytics",
                "information_schema",
            ],
            objectsByDatabase: [
                "app_database": [
                    WorkspaceDatabaseObject(name: "users", kind: .table),
                    WorkspaceDatabaseObject(name: "active_users", kind: .view),
                ],
                "analytics": [
                    WorkspaceDatabaseObject(name: "events", kind: .table)
                ]
            ],
            detailsByObject: [usersSelection: usersDetails],
            indexesByObject: [usersSelection: usersIndexes],
            dataByObject: [usersSelection: usersData]
        )
        let factory = RecordingWorkspaceSessionFactory(base: sessionFactory)
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(
                passwords: [profile.id: "secret"]
            ),
            sessionFactory: factory
        )

        await model.connect()

        #expect(model.connectionState == .connected)
        #expect(model.availableSchemas.isEmpty)
        #expect(model.selectedSchema == nil)
        #expect(
            model.visibleDatabases.map(\.name)
                == ["analytics", "app_database", "information_schema", "mysql"]
        )
        let configuration = await factory.configuration
        #expect(configuration?.password == "secret")

        await model.refreshSchemaCatalog()
        let appCatalog = try #require(model.schemaCatalog.database(named: "app_database"))
        let usersCatalog = try #require(appCatalog.object(named: "users"))
        #expect(usersCatalog.kind == .table)
        #expect(usersCatalog.columns.isEmpty)
        _ = await model.prepareCompletionColumns(
            for: [
                WorkspaceSchemaObjectReference(
                    databaseName: "app_database",
                    objectName: "users"
                )
            ]
        )
        let loadedUsersCatalog = try #require(
            model.schemaCatalog
                .database(named: "app_database")?
                .object(named: "users")
        )
        #expect(loadedUsersCatalog.columns.map(\.name) == ["id"])
        #expect(
            model.databases.first(where: { $0.name == "app_database" })?.objectsState
                == .notLoaded
        )

        let loadingTask = model.requestObjects(in: "app_database")
        model.requestObjects(in: "analytics")

        #expect(
            model.databases.first(where: { $0.name == "app_database" })?.objectsState
                == .queued
        )
        #expect(
            model.databases.first(where: { $0.name == "analytics" })?.objectsState
                == .queued
        )

        await loadingTask?.value

        guard
            let database = model.databases.first(
                where: { $0.name == "app_database" }
            ),
            case let .loaded(objects) = database.objectsState
        else {
            Issue.record("Expected loaded database objects.")
            await model.disconnect()
            return
        }
        #expect(objects.map(\.name) == ["users", "active_users"])
        #expect(
            model.databases.first(where: { $0.name == "analytics" })?.objectsState
                == .loaded([
                    WorkspaceDatabaseObject(name: "events", kind: .table)
                ])
        )

        await model.selectObject(usersSelection)
        await model.loadDetails(for: usersSelection)
        #expect(model.selectedObject == usersSelection)
        #expect(model.selectedObjectDetailsState == .loaded(usersDetails))

        await model.loadIndexes(for: usersSelection)
        #expect(model.selectedObjectIndexesState == .loaded(usersIndexes))

        await model.loadData(for: usersSelection, offset: 0, limit: 1)
        #expect(
            model.selectedObjectDataState == .loaded(
                WorkspaceDatabaseDataPage(
                    columns: usersData.columns,
                    rows: [usersData.rows[0]],
                    offset: 0,
                    limit: 1,
                    hasNextPage: true
                )
            )
        )

        await model.loadData(for: usersSelection, offset: 0, limit: 2)
        #expect(
            model.selectedObjectDataState == .loaded(
                WorkspaceDatabaseDataPage(
                    columns: usersData.columns,
                    rows: usersData.rows,
                    offset: 0,
                    limit: 2,
                    hasNextPage: false
                )
            )
        )

        let pageBeforeRefresh = try #require(
            model.selectedObjectDataState.page
        )
        await model.loadData(
            for: usersSelection,
            offset: 0,
            limit: 2,
            force: true
        )
        let pageAfterRefresh = try #require(
            model.selectedObjectDataState.page
        )
        #expect(pageAfterRefresh.rows == usersData.rows)
        #expect(pageAfterRefresh.rowCount == 2)
        #expect(pageAfterRefresh.rowStore !== pageBeforeRefresh.rowStore)

        await model.loadData(for: usersSelection, offset: 1, limit: 1)
        #expect(
            model.selectedObjectDataState == .loaded(
                WorkspaceDatabaseDataPage(
                    columns: usersData.columns,
                    rows: [usersData.rows[1]],
                    offset: 1,
                    limit: 1,
                    hasNextPage: false
                )
            )
        )

        let descendingName = WorkspaceDatabaseDataSort.descending(
            columnName: "name"
        )
        await model.loadData(
            for: usersSelection,
            offset: 0,
            limit: 2,
            sort: descendingName
        )
        #expect(
            model.selectedObjectDataState == .loaded(
                WorkspaceDatabaseDataPage(
                    columns: usersData.columns,
                    rows: [
                        WorkspaceDatabaseDataRow(
                            id: 0,
                            values: [.text("2"), .text("Bob")]
                        ),
                        WorkspaceDatabaseDataRow(
                            id: 1,
                            values: [.text("1"), .text("Alice")]
                        ),
                    ],
                    offset: 0,
                    limit: 2,
                    hasNextPage: false,
                    sort: descendingName
                )
            )
        )

        #expect(
            model.visibleDatabases.map(\.name)
                == ["analytics", "app_database", "information_schema", "mysql"]
        )
        await model.disconnect()
    }

    @Test
    func postgreSQLLoadsAndSelectsSchemasWithoutChangingMySQLBehavior() async {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Local PostgreSQL",
            groupID: nil,
            databaseType: .postgresql,
            host: "127.0.0.1",
            port: 5_437,
            username: "postgres",
            defaultDatabase: "app_database",
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
                databases: ["app_database"],
                schemasByDatabase: [
                    "app_database": ["audit", "public"],
                ],
                objectsByDatabase: [
                    "app_database": [
                        WorkspaceDatabaseObject(
                            name: "audit.events",
                            kind: .table
                        ),
                        WorkspaceDatabaseObject(
                            name: "public.users",
                            kind: .table
                        ),
                    ],
                ]
            )
        )

        await model.connect()
        await model.loadObjects(in: "app_database")

        #expect(model.availableSchemas == ["audit", "public"])
        #expect(model.selectedSchema == "public")
        model.selectSchema("audit")
        #expect(model.selectedSchema == "audit")
        model.selectSchema("missing")
        #expect(model.selectedSchema == "audit")

        let object = WorkspaceDatabaseObject(
            name: "audit.events",
            kind: .table
        )
        #expect(object.schemaName == "audit")
        #expect(object.nameWithinSchema == "events")

        let draft = WorkspaceNewTableDraft(
            databaseName: "app_database",
            schemaName: model.selectedSchema
        )
        draft.tableName = "new_events"
        #expect(
            draft.mutation.resultingSelection?.objectName
                == "audit.new_events"
        )
    }

    @Test
    func currentDatabaseRemainsAvailableWhenCatalogIsTemporarilyEmpty() async {
        let profile = makeProfile(storesCredential: false)
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            databaseContextName: "querycraft_driver_test",
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )

        await model.connect()

        #expect(model.connectionState == .connected)
        #expect(model.availableDatabaseNames == ["querycraft_driver_test"])
        await model.disconnect()
    }

    @Test
    func objectLoadFailurePreservesLocalizedDriverError() async throws {
        let profile = makeProfile(storesCredential: false)
        let message = "permission denied for schema audit [42501]"
        let session = WorkspaceObjectRefreshTestSession(
            objects: [],
            objectFetchErrorMessage: message
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: WorkspaceObjectRefreshTestSessionFactory(
                session: session
            )
        )

        await model.connect()
        await model.loadObjects(in: "app_database")

        let database = try #require(
            model.databases.first(where: { $0.name == "app_database" })
        )
        #expect(database.objectsState == .failed(message))
        await model.disconnect()
    }

    @Test
    func cancelledConnectionAttemptCannotCloseItsReplacementSession() async throws {
        let profile = makeProfile(storesCredential: false)
        let firstSession = WorkspaceObjectRefreshTestSession(
            objects: [],
            blocksConnect: true
        )
        let replacementSession = WorkspaceObjectRefreshTestSession(objects: [])
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: WorkspaceConnectionSequenceFactory(
                sessions: [firstSession, replacementSession]
            )
        )

        let firstConnection = Task { @MainActor in
            await model.connect()
        }
        await firstSession.waitUntilConnectStarted()
        firstConnection.cancel()

        let replacement = await model.connect()
        #expect(replacement === replacementSession)
        await firstSession.finishConnect()
        _ = await firstConnection.value

        #expect(await replacementSession.isConnected())
        #expect(model.connectionState == .connected)
        #expect(model.availableDatabaseNames == ["app_database"])
        await model.disconnect()
    }

    @Test
    func refreshObjectsPreservesLoadedSidebarUntilReplacementIsReady() async throws {
        let profile = makeProfile(storesCredential: false)
        let session = WorkspaceObjectRefreshTestSession(
            objects: [WorkspaceDatabaseObject(name: "users", kind: .table)]
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            databaseContextName: "app_database",
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: WorkspaceObjectRefreshTestSessionFactory(
                session: session
            )
        )

        await model.connect()
        await model.loadObjects(in: "app_database")
        #expect(
            model.currentDatabase?.objectsState == .loaded([
                WorkspaceDatabaseObject(name: "users", kind: .table)
            ])
        )

        await session.prepareBlockedRefresh(
            objects: [
                WorkspaceDatabaseObject(name: "users", kind: .table),
                WorkspaceDatabaseObject(name: "audit_log", kind: .table),
            ]
        )
        let refreshTask = Task { @MainActor in
            await model.refreshObjects(in: "app_database")
        }
        await session.waitUntilRefreshStarted()

        #expect(
            model.currentDatabase?.objectsState == .loaded([
                WorkspaceDatabaseObject(name: "users", kind: .table)
            ])
        )

        await session.finishRefresh()
        #expect(await refreshTask.value)
        #expect(
            model.currentDatabase?.objectsState == .loaded([
                WorkspaceDatabaseObject(name: "users", kind: .table),
                WorkspaceDatabaseObject(name: "audit_log", kind: .table),
            ])
        )
        await model.disconnect()
    }

    @Test
    func workspacePasswordIsUsedForProfileWithoutStoredCredential() async {
        let profile = makeProfile(storesCredential: false)
        let factory = RecordingWorkspaceSessionFactory(
            base: InMemoryWorkspaceSessionFactory(databases: ["app_database"])
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(
                profiles: [profile]
            ),
            credentialStore: InMemoryCredentialStore(),
            workspacePassword: "entered-password",
            sessionFactory: factory
        )

        await model.connect()

        #expect(await factory.configuration?.password == "entered-password")
        await model.disconnect()
    }

    @Test
    func lazilyLoadsColumnsCoalescesRequestsAndInvalidatesOnRefresh() async throws {
        let profile = makeProfile(storesCredential: false)
        let gate = CatalogPhaseGate()
        let recorder = CatalogRequestRecorder()
        let reference = WorkspaceSchemaObjectReference(
            databaseName: "test_estate_bus",
            objectName: "account_receivables"
        )
        let factory = PhasedCatalogSessionFactory(
            databases: ["test_estate_bus"],
            objectCatalog: [
                WorkspaceSchemaDatabase(
                    name: "test_estate_bus",
                    objects: [
                        WorkspaceSchemaObject(
                            name: "account_receivables",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            ],
            columnsByObject: [
                reference: [
                    WorkspaceSchemaColumn(
                        name: "id",
                        type: "bigint",
                        ordinalPosition: 1
                    )
                ]
            ],
            columnGate: gate,
            failsColumnLoad: false,
            recorder: recorder
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: factory
        )

        await model.connect()
        let publishedObjects = await waitUntil {
            model.schemaCatalog
                .database(named: "test_estate_bus")?
                .object(named: "account_receivables") != nil
        }
        #expect(publishedObjects)
        let objectOnlyTable = try #require(
            model.schemaCatalog
                .database(named: "test_estate_bus")?
                .object(named: "account_receivables")
        )
        #expect(objectOnlyTable.columns.isEmpty)
        #expect(await recorder.requests().isEmpty)

        let firstLoad = Task {
            await model.prepareCompletionColumns(for: [reference])
        }
        let secondLoad = Task {
            await model.prepareCompletionColumns(for: [reference])
        }
        #expect(await waitUntil { await recorder.requests().count == 1 })
        await gate.open()
        _ = await firstLoad.value
        _ = await secondLoad.value
        let loadedTable = try #require(
            model.schemaCatalog
                .database(named: "test_estate_bus")?
                .object(named: "account_receivables")
        )
        #expect(loadedTable.columns.map(\.name) == ["id"])
        #expect(await recorder.requests().count == 1)

        _ = await model.prepareCompletionColumns(for: [reference])
        #expect(await recorder.requests().count == 1)

        await model.refreshSchemaCatalog()
        let refreshedTable = try #require(
            model.schemaCatalog
                .database(named: "test_estate_bus")?
                .object(named: "account_receivables")
        )
        #expect(refreshedTable.columns.isEmpty)
        _ = await model.prepareCompletionColumns(for: [reference])
        #expect(await recorder.requests().count == 2)
        await model.disconnect()
    }

    @Test
    func relationChangesAndInvalidationCancelObsoleteColumnWork() async throws {
        let profile = makeProfile(storesCredential: false)
        let gate = CatalogPhaseGate()
        let recorder = CatalogRequestRecorder()
        let users = WorkspaceSchemaObjectReference(
            databaseName: "app",
            objectName: "users"
        )
        let events = WorkspaceSchemaObjectReference(
            databaseName: "app",
            objectName: "events"
        )
        let factory = PhasedCatalogSessionFactory(
            databases: ["app"],
            objectCatalog: [
                WorkspaceSchemaDatabase(
                    name: "app",
                    objects: [
                        WorkspaceSchemaObject(
                            name: "users",
                            kind: .table,
                            columns: []
                        ),
                        WorkspaceSchemaObject(
                            name: "events",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            ],
            columnsByObject: [
                users: [
                    WorkspaceSchemaColumn(
                        name: "id",
                        type: "bigint",
                        ordinalPosition: 1
                    )
                ],
                events: [
                    WorkspaceSchemaColumn(
                        name: "event_id",
                        type: "bigint",
                        ordinalPosition: 1
                    )
                ]
            ],
            columnGate: gate,
            failsColumnLoad: false,
            recorder: recorder
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: factory
        )

        await model.connect()
        #expect(await waitUntil {
            model.schemaCatalog.database(named: "app")?.object(named: "users") != nil
        })

        let staleLoad = Task {
            await model.prepareCompletionColumns(for: [users])
        }
        #expect(await waitUntil { await recorder.requests().count == 1 })

        let currentLoad = Task {
            await model.prepareCompletionColumns(for: [events])
        }
        #expect(await waitUntil { await recorder.requests().count == 2 })

        await gate.open()
        _ = await staleLoad.value
        _ = await currentLoad.value
        #expect(
            model.schemaCatalog.database(named: "app")?
                .object(named: "users")?.columns.isEmpty == true
        )
        #expect(
            model.schemaCatalog.database(named: "app")?
                .object(named: "events")?.columns.map(\.name) == ["event_id"]
        )

        model.invalidateCompletionColumns()
        _ = await model.prepareCompletionColumns(for: [events])
        #expect(await recorder.requests().count == 3)
        await model.disconnect()
    }

    @Test
    func keepsSchemaObjectsWhenAnOnDemandColumnLoadFails() async throws {
        let profile = makeProfile(storesCredential: false)
        let recorder = CatalogRequestRecorder()
        let reference = WorkspaceSchemaObjectReference(
            databaseName: "test_estate_bus",
            objectName: "admin_area"
        )
        let factory = PhasedCatalogSessionFactory(
            databases: ["test_estate_bus"],
            objectCatalog: [
                WorkspaceSchemaDatabase(
                    name: "test_estate_bus",
                    objects: [
                        WorkspaceSchemaObject(
                            name: "admin_area",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            ],
            columnsByObject: [:],
            columnGate: nil,
            failsColumnLoad: true,
            recorder: recorder
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: factory
        )

        await model.connect()
        #expect(await waitUntil {
            model.schemaCatalog
                .database(named: "test_estate_bus")?
                .object(named: "admin_area") != nil
        })
        _ = await model.prepareCompletionColumns(
            for: [
                WorkspaceSchemaObjectReference(
                    databaseName: "test_estate_bus",
                    objectName: "missing_table"
                )
            ]
        )
        #expect(await recorder.requests().isEmpty)
        _ = await model.prepareCompletionColumns(for: [reference])
        let table = try #require(
            model.schemaCatalog
                .database(named: "test_estate_bus")?
                .object(named: "admin_area")
        )
        #expect(table.columns.isEmpty)
        #expect(await recorder.requests() == [[reference]])
        _ = await model.prepareCompletionColumns(for: [reference])
        #expect(await recorder.requests() == [[reference]])
        await model.disconnect()
    }

    @Test
    func retainsColumnsOnlyForTheCurrentRelationContext() async throws {
        let profile = makeProfile(storesCredential: false)
        let recorder = CatalogRequestRecorder()
        let users = WorkspaceSchemaObjectReference(
            databaseName: "app",
            objectName: "users"
        )
        let events = WorkspaceSchemaObjectReference(
            databaseName: "app",
            objectName: "events"
        )
        let factory = PhasedCatalogSessionFactory(
            databases: ["app"],
            objectCatalog: [
                WorkspaceSchemaDatabase(
                    name: "app",
                    objects: [
                        WorkspaceSchemaObject(
                            name: "users",
                            kind: .table,
                            columns: []
                        ),
                        WorkspaceSchemaObject(
                            name: "events",
                            kind: .table,
                            columns: []
                        )
                    ]
                )
            ],
            columnsByObject: [
                users: [
                    WorkspaceSchemaColumn(
                        name: "id",
                        type: "bigint",
                        ordinalPosition: 1
                    )
                ],
                events: [
                    WorkspaceSchemaColumn(
                        name: "event_id",
                        type: "bigint",
                        ordinalPosition: 1
                    )
                ]
            ],
            columnGate: nil,
            failsColumnLoad: false,
            recorder: recorder
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: factory
        )

        await model.connect()
        #expect(await waitUntil {
            model.schemaCatalog.database(named: "app")?.object(named: "users") != nil
        })
        _ = await model.prepareCompletionColumns(for: [users])
        _ = await model.prepareCompletionColumns(for: [users])
        #expect(await recorder.requests() == [[users]])

        _ = await model.prepareCompletionColumns(for: [events])
        #expect(await recorder.requests() == [[users], [events]])
        #expect(
            model.schemaCatalog.database(named: "app")?
                .object(named: "users")?.columns.isEmpty == true
        )
        #expect(
            model.schemaCatalog.database(named: "app")?
                .object(named: "events")?.columns.map(\.name) == ["event_id"]
        )

        model.invalidateCompletionColumns()
        _ = await model.prepareCompletionColumns(for: [events])
        #expect(await recorder.requests() == [[users], [events], [events]])
        await model.disconnect()
    }

    @Test
    func exposesIndexesOnlyForTables() {
        #expect(
            WorkspaceDatabaseObjectDetailTab.available(for: .table)
                == [.data, .structure, .indexes, .options, .ddl]
        )
        #expect(
            WorkspaceDatabaseObjectDetailTab.available(for: .view)
                == [.data, .structure, .ddl]
        )
    }

    @Test
    func nativeSidebarSelectionKeepsModelSelectionInSync() async throws {
        let profile = makeProfile(storesCredential: false)
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["app"])
        )
        let table = WorkspaceDatabaseObjectSelection(
            databaseName: "app",
            objectName: "users",
            kind: .table
        )

        await model.connect()
        model.createQueryDocument()
        let documentID = try #require(model.queryDocuments.first?.id)
        #expect(model.selectedQueryDocumentID == documentID)
        #expect(model.sidebarSelection == nil)

        model.sidebarSelection = table
        #expect(model.selectedObject == table)
        #expect(model.selectedQueryDocumentID == nil)
        #expect(model.sidebarSelection == table)

        _ = model.activateQueryDocument(documentID)
        #expect(model.selectedObject == nil)
        #expect(model.selectedQueryDocumentID == documentID)
        #expect(model.sidebarSelection == nil)

        model.sidebarSelection = nil
        #expect(model.selectedObject == nil)
        #expect(model.selectedQueryDocumentID == documentID)
        #expect(model.sidebarSelection == nil)

        await model.disconnect()
    }

    @Test
    func queryCreationAndSwitchingDoNotInvalidateEmptySidebarSelection() async throws {
        let profile = makeProfile(storesCredential: false)
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["app"])
        )

        await model.connect()
        let firstDocument = try #require(model.createQueryDocument())
        let invalidationCount = Mutex(0)
        withObservationTracking {
            _ = model.sidebarSelection
        } onChange: {
            invalidationCount.withLock { $0 += 1 }
        }

        _ = model.createQueryDocument()
        _ = model.activateQueryDocument(firstDocument.id)

        #expect(invalidationCount.withLock { $0 } == 0)
        await model.disconnect()
    }

    @Test
    func closingTheSelectedQueryTabChoosesItsNextNeighbor() async throws {
        let profile = makeProfile(storesCredential: false)
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["app"])
        )

        await model.connect()
        model.createQueryDocument()
        model.createQueryDocument()
        model.createQueryDocument()
        let ids = model.queryDocuments.map(\.id)
        #expect(ids.count == 3)
        _ = model.activateQueryDocument(ids[1])

        #expect(await model.closeQueryDocument(ids[1]) == .closed)
        #expect(model.selectedQueryDocumentID == ids[2])
        #expect(model.queryDocuments.map(\.id) == [ids[0], ids[2]])

        await model.disconnect()
    }

    @Test
    func formatsIndexCompositionWithoutLosingPrefixOrDirection() {
        let index = WorkspaceDatabaseIndex(
            name: "idx_name_created",
            columns: [
                WorkspaceDatabaseIndexColumn(
                    sequence: 1,
                    name: "name",
                    prefixLength: 20,
                    direction: "A",
                    isExpression: false
                ),
                WorkspaceDatabaseIndexColumn(
                    sequence: 2,
                    name: "created_at",
                    prefixLength: nil,
                    direction: "D",
                    isExpression: false
                ),
            ],
            isUnique: false,
            type: "BTREE",
            cardinality: nil,
            isVisible: true,
            comment: ""
        )

        #expect(index.columnList == "name(20), created_at DESC")

        let expression = WorkspaceDatabaseIndexColumn(
            sequence: 1,
            name: "lower(`name`)",
            prefixLength: nil,
            direction: "A",
            isExpression: true
        )
        #expect(expression.displayName == "(lower(`name`))")
    }

    @Test
    func cyclesAColumnThroughServerSortStates() {
        let descending = WorkspaceDatabaseDataSort.none.toggled(for: "name")
        let ascending = descending.toggled(for: "name")
        let cleared = ascending.toggled(for: "name")
        let switchedColumn = ascending.toggled(for: "id")

        #expect(descending == .descending(columnName: "name"))
        #expect(ascending == .ascending(columnName: "name"))
        #expect(cleared == .none)
        #expect(switchedColumn == .descending(columnName: "id"))
    }

    @Test
    func defaultsTableDataToTheFirstPrimaryKeyAscending() {
        let columns = [
            WorkspaceDatabaseColumn(
                name: "tenant_id",
                type: "bigint",
                collation: nil,
                isNullable: false,
                key: "PRI",
                defaultValue: nil,
                extra: "",
                comment: ""
            ),
            WorkspaceDatabaseColumn(
                name: "id",
                type: "bigint",
                collation: nil,
                isNullable: false,
                key: "PRI",
                defaultValue: nil,
                extra: "",
                comment: ""
            ),
        ]

        #expect(
            WorkspaceDatabaseDataSort.defaultForTable(columns: columns)
                == .ascending(columnName: "tenant_id")
        )
        #expect(
            WorkspaceDatabaseDataSort.defaultForTable(
                columns: columns.map {
                    WorkspaceDatabaseColumn(
                        name: $0.name,
                        type: $0.type,
                        collation: $0.collation,
                        isNullable: $0.isNullable,
                        key: "",
                        defaultValue: $0.defaultValue,
                        extra: $0.extra,
                        comment: $0.comment
                    )
                }
            ) == .none
        )
    }

    @Test
    func safetyLockBlocksDataRowInsertBeforeCreatingAWriteSession() async {
        let profile = makeProfile(storesCredential: false)
        let factory = RecordingWorkspaceSessionFactory(
            base: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: factory
        )
        let insert = WorkspaceDatabaseDataRowInsert(
            selection: WorkspaceDatabaseObjectSelection(
                databaseName: "app",
                objectName: "users",
                kind: .table
            ),
            values: []
        )

        await #expect(
            throws: WorkspaceDatabaseDataRowInsertError.safetyLockEnabled
        ) {
            try await model.insertDataRow(insert)
        }
        #expect(await factory.configuration == nil)
    }

    private func makeProfile(storesCredential: Bool) -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: "Local MySQL",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: storesCredential,
            createdAt: .now
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func waitUntil(
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}

private actor RecordingWorkspaceSessionFactory: WorkspaceSessionFactory {
    private let base: any WorkspaceSessionFactory
    private(set) var configuration: DatabaseConnectionConfiguration?

    init(base: any WorkspaceSessionFactory) {
        self.base = base
    }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        self.configuration = configuration
        return await base.makeSession(configuration: configuration)
    }

    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> (any WorkspaceSession)? {
        await base.makeSchemaCatalogSession(configuration: configuration)
    }
}

private struct WorkspaceObjectRefreshTestSessionFactory:
    WorkspaceSessionFactory
{
    let session: WorkspaceObjectRefreshTestSession

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        session
    }
}

private actor WorkspaceConnectionSequenceFactory: WorkspaceSessionFactory {
    private var sessions: [any WorkspaceSession]

    init(sessions: [any WorkspaceSession]) {
        self.sessions = sessions
    }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        sessions.removeFirst()
    }
}

private actor WorkspaceObjectRefreshTestSession: WorkspaceSession {
    private let connectStarted = WorkspaceObjectRefreshTestSignal()
    private let connectRelease = WorkspaceObjectRefreshTestSignal()
    private let refreshStarted = WorkspaceObjectRefreshTestSignal()
    private let refreshRelease = WorkspaceObjectRefreshTestSignal()
    private var objects: [WorkspaceDatabaseObject]
    private var replacementObjects: [WorkspaceDatabaseObject]?
    private let objectFetchErrorMessage: String?
    private var blocksConnect: Bool
    private var blocksNextObjectFetch = false
    private var connected = false

    init(
        objects: [WorkspaceDatabaseObject],
        blocksConnect: Bool = false,
        objectFetchErrorMessage: String? = nil
    ) {
        self.objects = objects
        self.blocksConnect = blocksConnect
        self.objectFetchErrorMessage = objectFetchErrorMessage
    }

    func connect() async throws {
        if blocksConnect {
            blocksConnect = false
            await connectStarted.signal()
            await connectRelease.wait()
            try Task.checkCancellation()
        }
        connected = true
    }

    func isConnected() async -> Bool {
        connected
    }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        return ["app_database"]
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        try requireConnection()
        if let objectFetchErrorMessage {
            throw WorkspaceObjectFetchTestError(
                errorDescription: objectFetchErrorMessage
            )
        }
        if blocksNextObjectFetch {
            blocksNextObjectFetch = false
            await refreshStarted.signal()
            await refreshRelease.wait()
            try Task.checkCancellation()
            if let replacementObjects {
                objects = replacementObjects
                self.replacementObjects = nil
            }
        }
        return objects
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
        WorkspaceDatabaseDataFetchResult(columns: [], hasNextPage: false)
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        0
    }

    func close() async {
        connected = false
        await refreshRelease.signal()
    }

    func prepareBlockedRefresh(
        objects: [WorkspaceDatabaseObject]
    ) {
        replacementObjects = objects
        blocksNextObjectFetch = true
    }

    func waitUntilConnectStarted() async {
        await connectStarted.wait()
    }

    func finishConnect() async {
        await connectRelease.signal()
    }

    func waitUntilRefreshStarted() async {
        await refreshStarted.wait()
    }

    func finishRefresh() async {
        await refreshRelease.signal()
    }

    private func requireConnection() throws {
        guard connected else {
            throw WorkspaceSessionError.notConnected
        }
    }
}

private struct WorkspaceObjectFetchTestError: LocalizedError, Sendable {
    let errorDescription: String?
}

private actor WorkspaceObjectRefreshTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}
