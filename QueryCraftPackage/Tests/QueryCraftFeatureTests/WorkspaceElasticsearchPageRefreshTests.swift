import Foundation
import Testing

@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchPageRefreshTests {
    @Test
    func refreshedOffsetHandlesEmptyPagesAndTheDirectWindow() {
        let cases: [(Int, Int, Int?, Int)] = [
            (4, 2, 4, 2), (4, 2, 5, 4), (4, 2, 0, 0),
            (4, 2, nil, 0), (200, 200, 199, 0), (400, 200, 201, 200),
            (9_800, 200, 12_000, 9_800), (10_000, 200, 12_000, 0),
            (10_000, 200, 9_999, 9_800), (25, 10, 30, 25), (25, 10, 25, 20),
            (Int.max, 200, Int.max, 0), (0, 0, 1, 0),
        ]
        for (requested, limit, count, expected) in cases {
            #expect(WorkspaceElasticsearchPageRefresh.offset(
                requested: requested, limit: limit, totalCount: count
            ) == expected)
        }
    }

    @Test
    func refreshClosesOldSnapshotAndLoadsPreviousPageWithoutEmptyIntermediateState() async throws {
        let (model, server, selection) = await fixture(total: 6)
        await model.loadData(for: selection, offset: 4, limit: 2)
        let oldPage = try #require(model.selectedObjectDataState.page)
        let oldRequest = try #require(await server.requests.last)
        await server.setTotal(4)
        let started = PageRefreshSignal()
        let release = PageRefreshSignal()
        await server.holdPage(started: started, release: release)

        let task = Task { await model.loadData(for: selection, offset: 4, limit: 2, force: true) }
        await started.wait()
        #expect(model.selectedObjectDataState.isFetching)
        #expect(model.selectedObjectDataState.page?.rowStore === oldPage.rowStore)
        #expect(model.selectedObjectDataState.page?.rowCount == 2)
        #expect(await server.closed.contains(oldRequest.sessionID))
        await release.open()
        await task.value

        let refreshed = try #require(model.selectedObjectDataState.page)
        #expect(refreshed.offset == 2)
        #expect(refreshed.rowCount == 2)
        #expect(refreshed.rowStore !== oldPage.rowStore)
        #expect(model.selectedObjectDataCountState == .loaded(4))
        let requests = await server.requests
        #expect(requests.map(\.offset) == [4, 2])
        #expect(requests[0].sessionID != requests[1].sessionID)
        await model.disconnect()
    }

    @Test
    func deletingEverythingReturnsToAnEmptyFirstPage() async throws {
        let (model, server, selection) = await fixture(total: 3)
        await model.loadData(for: selection, offset: 2, limit: 2)
        await server.setTotal(0)
        await model.loadData(for: selection, offset: 2, limit: 2, force: true)
        let page = try #require(model.selectedObjectDataState.page)
        #expect(page.offset == 0)
        #expect(page.rowCount == 0)
        #expect(!page.hasNextPage)
        #expect(model.selectedObjectDataCountState == .loaded(0))
        await model.disconnect()
    }

    @Test
    func refreshingAPartiallyDeletedPagePreservesRangeSortAndFilter() async throws {
        let (model, server, selection) = await fixture(total: 6)
        let sort = WorkspaceDatabaseDataSort.ascending(columnName: "ordinal")
        let filter = WorkspaceDatabaseDataFilter(conditions: [
            WorkspaceDatabaseDataFilterCondition(
                columnName: "scenario", columnKind: .text,
                operation: .equal, value: "normal"
            ),
        ])
        await model.loadData(for: selection, offset: 4, limit: 2, sort: sort, filter: filter)
        await server.setTotal(5)
        await model.loadData(for: selection, offset: 4, limit: 2, sort: sort, filter: filter, force: true)
        let page = try #require(model.selectedObjectDataState.page)
        #expect(page.offset == 4)
        #expect(page.rowCount == 1)
        #expect(page.sort == sort)
        #expect(page.filter == filter)
        #expect(await server.requests.last?.filter == filter)
        #expect(await server.countFilters.last == filter)
        await model.disconnect()
    }

    @Test
    func normalPagingKeepsItsExistingReadSession() async throws {
        let (model, server, selection) = await fixture(total: 5)
        await model.loadData(for: selection, offset: 0, limit: 2)
        await model.loadData(for: selection, offset: 2, limit: 2)
        let requests = await server.requests
        #expect(requests.map(\.offset) == [0, 2])
        #expect(requests[0].sessionID == requests[1].sessionID)
        await model.disconnect()
    }

    @Test
    func relationalRefreshDoesNotApplyDocumentPageRecovery() async throws {
        let (model, server, selection) = await fixture(total: 6, databaseType: .mysql)
        await model.loadData(for: selection, offset: 4, limit: 2)
        await server.setTotal(4)
        await model.loadData(for: selection, offset: 4, limit: 2, force: true)
        let page = try #require(model.selectedObjectDataState.page)
        #expect(page.offset == 4)
        let requests = await server.requests
        #expect(requests[0].sessionID == requests[1].sessionID)
        await model.disconnect()
    }

    @Test
    func cancellationWhileCountingDoesNotFetchOrPublishAReplacement() async throws {
        let (model, server, selection) = await fixture(total: 3)
        let started = PageRefreshSignal()
        let release = PageRefreshSignal()
        await server.holdCount(started: started, release: release)
        let task = Task { await model.loadData(for: selection, offset: 2, limit: 2, force: true) }
        await started.wait()
        task.cancel()
        await release.open()
        await task.value
        #expect(await server.requests.isEmpty)
        #expect(model.selectedObjectDataState.isStopped)
        await model.disconnect()
    }

    @Test
    func changingObjectWhileCountingRejectsLateRefreshResults() async throws {
        let (model, server, selection) = await fixture(total: 3)
        let started = PageRefreshSignal()
        let release = PageRefreshSignal()
        await server.holdCount(started: started, release: release)
        let task = Task { await model.loadData(for: selection, offset: 2, limit: 2, force: true) }
        await started.wait()
        let other = WorkspaceDatabaseObjectSelection(
            databaseName: "Elasticsearch", objectName: "other", kind: .elasticsearchIndex
        )
        await model.selectObject(other)
        await release.open()
        await task.value
        #expect(model.selectedObject == other)
        #expect(model.selectedObjectDataState == .notLoaded)
        #expect(await server.requests.isEmpty)
        await model.disconnect()
    }

    private func fixture(
        total: Int, databaseType: DatabaseType = .elasticsearch
    ) async -> (WorkspaceModel, PageRefreshServer, WorkspaceDatabaseObjectSelection) {
        let server = PageRefreshServer(total: total)
        let profile = ConnectionProfile(
            id: UUID(), name: "Page refresh test", groupID: nil, databaseType: databaseType,
            host: "127.0.0.1", port: 9200, username: "", defaultDatabase: nil,
            tlsMode: .disabled, storesCredential: false, createdAt: .now
        )
        let model = WorkspaceModel(
            profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: PageRefreshSessionFactory(server: server)
        )
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "Elasticsearch", objectName: "logs",
            kind: databaseType == .elasticsearch ? .elasticsearchIndex : .table
        )
        await model.connect()
        await model.selectObject(selection)
        return (model, server, selection)
    }
}

private actor PageRefreshSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor PageRefreshServer {
    struct Request: Sendable {
        let sessionID: Int
        let offset: Int
        let filter: WorkspaceDatabaseDataFilter
    }

    var total: Int
    private(set) var requests: [Request] = []
    private(set) var countFilters: [WorkspaceDatabaseDataFilter] = []
    private(set) var closed: Set<Int> = []
    private var pageGate: (PageRefreshSignal, PageRefreshSignal)?
    private var countGate: (PageRefreshSignal, PageRefreshSignal)?

    init(total: Int) { self.total = total }
    func setTotal(_ total: Int) { self.total = total }
    func close(_ id: Int) { closed.insert(id) }
    func record(_ request: Request) { requests.append(request) }
    func holdPage(started: PageRefreshSignal, release: PageRefreshSignal) { pageGate = (started, release) }
    func holdCount(started: PageRefreshSignal, release: PageRefreshSignal) { countGate = (started, release) }

    func finishPage() async {
        if let (started, release) = pageGate {
            await started.open()
            await release.wait()
        }
    }

    func count(filter: WorkspaceDatabaseDataFilter) async -> Int {
        countFilters.append(filter)
        if let (started, release) = countGate {
            await started.open()
            await release.wait()
        }
        return total
    }
}

private actor PageRefreshSessionFactory: WorkspaceSessionFactory {
    let server: PageRefreshServer
    private var nextID = 0
    init(server: PageRefreshServer) { self.server = server }

    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession {
        nextID += 1
        return PageRefreshSession(id: nextID, server: server)
    }
}

private actor PageRefreshSession: WorkspaceSession {
    let id: Int
    let server: PageRefreshServer
    init(id: Int, server: PageRefreshServer) { self.id = id; self.server = server }

    func connect() async throws {}
    func fetchDatabases() async throws -> [String] { ["Elasticsearch"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails {
        throw WorkspaceSessionError.metadataUnavailable(object: object.name)
    }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func close() async { await server.close(id) }

    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int {
        await server.count(filter: .empty)
    }

    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String, filter: WorkspaceDatabaseDataFilter) async throws -> Int {
        await server.count(filter: filter)
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try await fetchDataPage(for: object, in: database, offset: offset, limit: limit,
                                sort: sort, filter: .empty, onBatch: onBatch)
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int,
        sort: WorkspaceDatabaseDataSort, filter: WorkspaceDatabaseDataFilter,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        await server.record(.init(sessionID: id, offset: offset, filter: filter))
        let total = await server.total
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "ordinal")]
        let rows = (min(offset, total)..<min(offset + limit, total)).map {
            WorkspaceDatabaseDataRow(id: $0, values: [.text(String($0))])
        }
        await onBatch(.init(columns: columns, rows: rows))
        await server.finishPage()
        return .init(columns: columns, hasNextPage: offset + rows.count < total)
    }
}
