import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceDataCancellationTests {
    @Test
    func disconnectedDataPageSessionReconnectsAndRetriesReadOnce() async throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        )
        let mainSession = ControlledWorkspaceSession(role: .main)
        let disconnectedSession = DisconnectedDataWorkspaceSession()
        let firstRecoverySession = ImmediateDataWorkspaceSession()
        let secondRecoverySession = ImmediateDataWorkspaceSession()
        let factory = SequencedWorkspaceSessionFactory(
            sessions: [
                mainSession,
                disconnectedSession,
                firstRecoverySession,
                secondRecoverySession,
            ]
        )
        let model = makeModel(sessionFactory: factory)
        await model.connect()
        await model.selectObject(selection)

        await model.loadData(for: selection, offset: 0, limit: 2)

        let page = try #require(model.selectedObjectDataState.page)
        #expect(model.selectedObjectDataState == .loaded(page))
        #expect(page.rows.map(\.values) == [[.text("recovered")]])
        #expect(await disconnectedSession.fetchCount() == 1)
        #expect(await disconnectedSession.wasClosed())
        let recoveryFetchCount = await firstRecoverySession.fetchCount()
            + secondRecoverySession.fetchCount()
        #expect(recoveryFetchCount == 1)
    }

    @Test
    func stoppingDataWorkKeepsReceivedRowsAndClosesBothSessions() async throws {
        let fixture = makeFixture()
        await fixture.model.connect()
        await fixture.model.selectObject(fixture.selection)

        let loadTask = Task {
            await fixture.model.loadData(
                for: fixture.selection,
                offset: 0,
                limit: 2
            )
        }

        await fixture.rowSession.waitUntilFirstBatch()
        await fixture.countSession.waitUntilCountStarted()
        await fixture.model.stopDataWork(
            for: fixture.selection,
            reason: .userStopped
        )
        await loadTask.value

        guard
            case let .stopped(page?) = fixture.model.selectedObjectDataState
        else {
            Issue.record("Expected a stopped page containing received rows.")
            return
        }

        #expect(page.rowCount == 1)
        #expect(page.row(at: 0)?.values == [.text("first")])
        #expect(await fixture.rowSession.wasClosed())
        #expect(await fixture.countSession.wasClosed())
        #expect(fixture.model.selectedObjectDataCountState == .notLoaded)

        await fixture.model.loadData(
            for: fixture.selection,
            offset: 0,
            limit: 2
        )
        #expect(fixture.model.selectedObjectDataState == .stopped(page))
    }

    @Test
    func switchingSelectionDiscardsAnIncompletePage() async throws {
        let fixture = makeFixture()
        let otherSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "audit_log",
            kind: .table
        )
        await fixture.model.connect()
        await fixture.model.selectObject(fixture.selection)

        let loadTask = Task {
            await fixture.model.loadData(
                for: fixture.selection,
                offset: 0,
                limit: 2
            )
        }

        await fixture.rowSession.waitUntilFirstBatch()
        await fixture.countSession.waitUntilCountStarted()
        await fixture.model.selectObject(otherSelection)
        await loadTask.value
        await fixture.model.selectObject(fixture.selection)

        #expect(fixture.model.selectedObjectDataState == .notLoaded)
        #expect(await fixture.rowSession.wasClosed())
        #expect(await fixture.countSession.wasClosed())
    }

    @Test
    func creatingQueryPublishesDocumentBeforeDataCleanupFinishes() async throws {
        let fixture = makeFixture()
        await fixture.model.connect()
        await fixture.model.selectObject(fixture.selection)

        let loadTask = Task {
            await fixture.model.loadData(
                for: fixture.selection,
                offset: 0,
                limit: 2
            )
        }
        await fixture.rowSession.waitUntilFirstBatch()
        await fixture.countSession.waitUntilCountStarted()

        let document = try #require(fixture.model.createQueryDocument())

        #expect(fixture.model.selectedQueryDocumentID == document.id)
        #expect(fixture.model.selectedObject == nil)

        await loadTask.value
        #expect(await fixture.rowSession.wasClosed())
        #expect(await fixture.countSession.wasClosed())
    }

    @Test
    func rowAndCountSessionsReceiveTheSameImmutableFilter() async throws {
        let fixture = makeFixture()
        let filter = WorkspaceDatabaseDataFilter(
            conditions: [
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "value",
                    columnKind: .text,
                    operation: .contains,
                    value: "first"
                )
            ]
        )
        await fixture.model.connect()
        await fixture.model.selectObject(fixture.selection)

        let loadTask = Task {
            await fixture.model.loadData(
                for: fixture.selection,
                offset: 0,
                limit: 2,
                filter: filter
            )
        }

        await fixture.rowSession.waitUntilFirstBatch()
        await fixture.countSession.waitUntilCountStarted()

        #expect(await fixture.rowSession.receivedPageDataFilter() == filter)
        #expect(await fixture.countSession.receivedCountDataFilter() == filter)

        await fixture.model.stopDataWork(
            for: fixture.selection,
            reason: .userStopped
        )
        await loadTask.value
    }

    @Test
    func changingFilterRejectsLateRowsFromTheSupersededLoad() async throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        )
        let mainSession = ControlledWorkspaceSession(role: .main)
        let oldRows = ControlledWorkspaceSession(role: .rows("old"))
        let oldCount = ControlledWorkspaceSession(role: .count(2))
        let newRows = ControlledWorkspaceSession(role: .rows("new"))
        let newCount = ControlledWorkspaceSession(role: .count(2))
        let factory = SequencedWorkspaceSessionFactory(
            sessions: [mainSession, oldRows, oldCount, newRows, newCount]
        )
        let model = makeModel(sessionFactory: factory)
        let oldFilter = makeFilter(value: "old")
        let newFilter = makeFilter(value: "new")
        await model.connect()
        await model.selectObject(selection)

        let oldLoad = Task {
            await model.loadData(
                for: selection,
                offset: 0,
                limit: 2,
                filter: oldFilter
            )
        }
        await oldRows.waitUntilFirstBatch()
        await oldCount.waitUntilCountStarted()

        let newLoad = Task {
            await model.loadData(
                for: selection,
                offset: 0,
                limit: 2,
                filter: newFilter
            )
        }
        await newRows.waitUntilFirstBatch()
        await newCount.waitUntilCountStarted()

        #expect(model.selectedObjectDataState.page?.rows.map(\.values) == [[.text("new")]])
        #expect(await oldRows.wasClosed())
        #expect(await oldCount.wasClosed())

        await model.stopDataWork(for: selection, reason: .userStopped)
        await oldLoad.value
        await newLoad.value
    }

    @Test
    func lateStopForPreviousSelectionDoesNotStopCurrentLoad() async throws {
        let oldSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        )
        let newSelection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "audit_log",
            kind: .table
        )
        let mainSession = ControlledWorkspaceSession(role: .main)
        let oldRows = ControlledWorkspaceSession(role: .rows("old"))
        let oldCount = ControlledWorkspaceSession(role: .count(2))
        let newRows = ControlledWorkspaceSession(role: .rows("new"))
        let newCount = ControlledWorkspaceSession(role: .count(2))
        let factory = SequencedWorkspaceSessionFactory(
            sessions: [mainSession, oldRows, oldCount, newRows, newCount]
        )
        let model = makeModel(sessionFactory: factory)
        await model.connect()
        await model.selectObject(oldSelection)

        let oldLoad = Task {
            await model.loadData(for: oldSelection, offset: 0, limit: 2)
        }
        await oldRows.waitUntilFirstBatch()
        await oldCount.waitUntilCountStarted()
        await model.selectObject(newSelection)
        await oldLoad.value

        let newLoad = Task {
            await model.loadData(for: newSelection, offset: 0, limit: 2)
        }
        await newRows.waitUntilFirstBatch()
        await newCount.waitUntilCountStarted()

        await model.stopDataWork(
            for: oldSelection,
            reason: .selectionChanged
        )

        #expect(await newRows.wasClosed() == false)
        #expect(await newCount.wasClosed() == false)

        await newRows.finish()
        await newCount.finish()
        await newLoad.value

        guard case let .loaded(page) = model.selectedObjectDataState else {
            Issue.record("Expected the current table load to finish.")
            return
        }
        #expect(page.rows.map(\.values) == [
            [.text("new")],
            [.text("new-late")],
        ])
    }

    private func makeFixture() -> WorkspaceDataCancellationFixture {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "app_database",
            objectName: "users",
            kind: .table
        )
        let mainSession = ControlledWorkspaceSession(role: .main)
        let rowSession = ControlledWorkspaceSession(role: .rows("first"))
        let countSession = ControlledWorkspaceSession(role: .count(2))
        let factory = SequencedWorkspaceSessionFactory(
            sessions: [mainSession, rowSession, countSession]
        )
        let model = makeModel(sessionFactory: factory)
        return WorkspaceDataCancellationFixture(
            model: model,
            selection: selection,
            rowSession: rowSession,
            countSession: countSession
        )
    }

    private func makeModel(
        sessionFactory: any WorkspaceSessionFactory
    ) -> WorkspaceModel {
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Cancellation Test",
            groupID: nil,
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            createdAt: .now
        )
        return WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: sessionFactory
        )
    }

    private func makeFilter(value: String) -> WorkspaceDatabaseDataFilter {
        WorkspaceDatabaseDataFilter(
            conditions: [
                WorkspaceDatabaseDataFilterCondition(
                    columnName: "value",
                    columnKind: .text,
                    operation: .equal,
                    value: value
                )
            ]
        )
    }
}

private struct WorkspaceDataCancellationFixture {
    let model: WorkspaceModel
    let selection: WorkspaceDatabaseObjectSelection
    let rowSession: ControlledWorkspaceSession
    let countSession: ControlledWorkspaceSession
}

private actor SequencedWorkspaceSessionFactory: WorkspaceSessionFactory {
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

private actor ControlledWorkspaceSession: WorkspaceSession {
    enum Role: Sendable {
        case main
        case rows(String)
        case count(Int)
    }

    private let role: Role
    private let release = AsyncSignal()
    private let firstBatchDelivered = AsyncSignal()
    private let countStarted = AsyncSignal()
    private var isConnected = false
    private var closed = false
    private var pageDataFilter: WorkspaceDatabaseDataFilter?
    private var countDataFilter: WorkspaceDatabaseDataFilter?

    init(role: Role) {
        self.role = role
    }

    func connect() async throws {
        isConnected = true
    }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        return ["app_database"]
    }

    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        try requireConnection()
        return []
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
        try requireConnection()
        return []
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try requireConnection()
        guard case let .rows(firstValue) = role else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }

        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        await onBatch(
            WorkspaceDatabaseDataBatch(
                columns: columns,
                rows: [
                    WorkspaceDatabaseDataRow(
                        id: 0,
                        values: [.text(firstValue)]
                    )
                ]
            )
        )
        await firstBatchDelivered.signal()
        await release.wait()

        await onBatch(
            WorkspaceDatabaseDataBatch(
                columns: columns,
                rows: [
                    WorkspaceDatabaseDataRow(
                        id: 1,
                        values: [.text("\(firstValue)-late")]
                    )
                ]
            )
        )
        return WorkspaceDatabaseDataFetchResult(
            columns: columns,
            hasNextPage: false
        )
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        pageDataFilter = filter
        return try await fetchDataPage(
            for: object,
            in: database,
            offset: offset,
            limit: limit,
            sort: sort,
            onBatch: onBatch
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        try requireConnection()
        guard case let .count(value) = role else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }
        await countStarted.signal()
        await release.wait()
        return value
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int {
        countDataFilter = filter
        return try await fetchDataCount(for: object, in: database)
    }

    func close() async {
        isConnected = false
        closed = true
        await release.signal()
    }

    func waitUntilFirstBatch() async {
        await firstBatchDelivered.wait()
    }

    func waitUntilCountStarted() async {
        await countStarted.wait()
    }

    func wasClosed() -> Bool {
        closed
    }

    func finish() async {
        await release.signal()
    }

    func receivedPageDataFilter() -> WorkspaceDatabaseDataFilter? {
        pageDataFilter
    }

    func receivedCountDataFilter() -> WorkspaceDatabaseDataFilter? {
        countDataFilter
    }

    private func requireConnection() throws {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
    }
}

private actor DisconnectedDataWorkspaceSession: WorkspaceSession {
    private var isConnected = false
    private var fetches = 0
    private var closed = false

    func connect() async throws {
        isConnected = true
    }

    func isConnected() async -> Bool {
        isConnected
    }

    func fetchDatabases() async throws -> [String] {
        ["app_database"]
    }

    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        []
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
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        fetches += 1
        isConnected = false
        throw WorkspaceSessionError.notConnected
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw WorkspaceSessionError.notConnected
    }

    func close() async {
        isConnected = false
        closed = true
    }

    func fetchCount() -> Int {
        fetches
    }

    func wasClosed() -> Bool {
        closed
    }
}

private actor ImmediateDataWorkspaceSession: WorkspaceSession {
    private var isConnected = false
    private var fetches = 0

    func connect() async throws {
        isConnected = true
    }

    func isConnected() async -> Bool {
        isConnected
    }

    func fetchDatabases() async throws -> [String] {
        ["app_database"]
    }

    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        []
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
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        guard isConnected else { throw WorkspaceSessionError.notConnected }
        fetches += 1
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        await onBatch(
            WorkspaceDatabaseDataBatch(
                columns: columns,
                rows: [
                    WorkspaceDatabaseDataRow(
                        id: offset,
                        values: [.text("recovered")]
                    )
                ]
            )
        )
        return WorkspaceDatabaseDataFetchResult(
            columns: columns,
            hasNextPage: false
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        guard isConnected else { throw WorkspaceSessionError.notConnected }
        return 1
    }

    func close() async {
        isConnected = false
    }

    func fetchCount() -> Int {
        fetches
    }
}

private actor AsyncSignal {
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
