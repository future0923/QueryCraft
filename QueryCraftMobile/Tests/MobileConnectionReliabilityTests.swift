import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileConnectionReliabilityTests {
    private let configuration = MariaDBTransportConfiguration(host: "127.0.0.1", port: 1, username: "unused", password: nil, database: "db", tlsMode: .disabled)

    @Test func confirmedCommitFinishingDuringBackgroundRequiresExplicitTableReload() async throws {
        let service = ReliabilityBrowser(), writer = ReliabilityConfirmedWriter()
        let model = MobileBrowserModel(configuration: configuration, service: service, mutationService: writer)
        await model.loadDatabases().value; await model.loadObjects()?.value
        let object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
        await model.selectObject(object)?.value
        let page = try #require(model.snapshot), changes = try #require(model.currentChanges)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "confirmed", mode: .value)
        changes.safetyLock.disable()
        let operation = try #require(changes.submit()); #expect(await writer.waitForGate())
        model.setBackgrounded(true)
        await writer.release(); await operation.value
        #expect(!changes.hasChanges); #expect(!changes.needsVerification)
        #expect(changes.requiresReload); #expect(await service.pageCalls == 1)
        model.setBackgrounded(false)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try changes.request(page: page, row: 0, column: 1) }
        await model.loadTable()?.value
        #expect(!changes.requiresReload); #expect(await service.pageCalls == 2)
    }

    @Test func uncertainTableDiscardRemainsReadonlyAfterFailedRefresh() async throws {
        let service = ReliabilityBrowser()
        let model = MobileBrowserModel(configuration: configuration, service: service, mutationService: ReliabilityUnknownWriter())
        await model.loadDatabases().value; await model.loadObjects()?.value
        let object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
        await model.selectObject(object)?.value
        let page = try #require(model.snapshot), changes = try #require(model.currentChanges)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "unknown", mode: .value)
        changes.safetyLock.disable(); await changes.submit()?.value
        #expect(changes.needsVerification)
        await service.holdNext()
        changes.discard() // Starts the ordinary table reload, without clearing the verification fence.
        #expect(await service.waitForHeldRequest())
        #expect(changes.requiresReload); #expect(!changes.hasChanges)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try changes.request(page: page, row: 0, column: 1) }
        await service.failHeld();
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isLoadingTable, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.tableError != nil); #expect(changes.requiresReload)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try changes.request(page: page, row: 0, column: 1) }
        await model.loadTable()?.value
        #expect(!changes.requiresReload); #expect(model.tableError == nil)
        _ = try changes.request(page: try #require(model.snapshot), row: 0, column: 1)
    }

    @Test func backgroundCancelsPartialExportRejectsLateFileAndAllowsExplicitRetry() async throws {
        let data = MobileGridData(preview: .init(result: .init(columns: ["id"], rows: [["1"]])))
        let writer = ReliabilityExportWriter()
        let model = MobileDataExportModel(snapshot: .init(data: data, name: "owned", scopeDescription: "loaded"), writer: writer)
        model.format = .json
        let operation = try #require(model.prepare())
        #expect(await writer.waitForGate())
        model.setBackgrounded(true)
        #expect(!model.isExporting); #expect(model.message?.contains("暂停") == true)
        await writer.release(); await operation.value
        #expect(model.file == nil)
        model.setBackgrounded(false)
        #expect(model.file == nil); #expect(await writer.calls == 1)
        await model.prepare()?.value
        #expect(model.file != nil); #expect(await writer.calls == 2)
        model.cancel()
    }

    @Test func backgroundRetainsTableDraftAndRejectsLatePageUntilExplicitRefresh() async throws {
        let service = ReliabilityBrowser(), model = MobileBrowserModel(configuration: configuration, service: service)
        await model.loadDatabases().value; await model.loadObjects()?.value
        let object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
        await model.selectObject(object)?.value
        let page = try #require(model.snapshot), changes = try #require(model.currentChanges)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "draft", mode: .value)
        let revision = model.revision
        changes.safetyLock.disable()
        await service.holdNext()
        let refresh = try #require(model.loadTable(offset: 100))
        #expect(await service.waitForHeldRequest())
        model.setBackgrounded(true)
        #expect(!model.isLoadingTable); #expect(changes.safetyLock.isEnabled)
        #expect(model.snapshot?.offset == 0); #expect(model.revision == revision)
        #expect(model.currentChanges === changes); #expect(changes.hasChanges)
        #expect(model.tableError == MobileConnectionFeedback.paused)
        #expect(model.loadTable() == nil); #expect(model.loadObjects() == nil)
        await service.release(); await refresh.value
        #expect(model.snapshot?.offset == 0); #expect(model.revision == revision)
        let calls = await service.pageCalls
        model.setBackgrounded(false)
        #expect(await service.pageCalls == calls); #expect(changes.hasChanges)
        await model.loadTable()?.value
        #expect(model.tableError == nil); #expect(model.currentChanges === changes)
        #expect(changes.displayData(page: try #require(model.snapshot), details: nil).cell(row: 0, column: 1) == .text("draft"))
    }

    @Test func backgroundRejectsLateQueryAndKeepsEditorAndCommittedResults() async throws {
        let executor = ReliabilityQuery(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        model.sql = "SELECT id,name FROM t"; model.database = "db"
        await model.execute()?.value
        let identity = model.resultID, editing = try #require(model.editing), page = try #require(model.editingPage)
        try editing.stage(editing.request(page: page, row: 0, column: 1), text: "pending", mode: .value)
        model.setBackgrounded(true); model.setBackgrounded(false)
        #expect(model.editing === editing); #expect(editing.hasChanges); #expect(model.resultID == identity)
        #expect(editing.safetyLock.isEnabled); #expect(await executor.calls == 1)
        editing.discard()
        await executor.holdNext()
        let refresh = try #require(model.execute()); #expect(await executor.waitForHeldRequest())
        model.sql = "SELECT 99 -- next draft"
        model.setBackgrounded(true)
        #expect(!model.isLoading); #expect(model.resultID == identity)
        #expect(model.errorMessage == MobileConnectionFeedback.paused); #expect(model.execute() == nil)
        await executor.release(); await refresh.value
        #expect(model.resultID == identity); #expect(model.result?.rows == [["1", "before"]])
        model.setBackgrounded(false)
        #expect(await executor.calls == 2); #expect(model.sql == "SELECT 99 -- next draft")
        await model.execute()?.value
        #expect(model.resultID != identity); #expect(model.errorMessage == nil)
    }

    @Test func backgroundDuringEditingMetadataKeepsResultReadonlyUntilManualRetry() async throws {
        let metadata = QueryEditingMetadata(delaysFirst: true)
        let model = MobileQueryModel(executor: QueryEditingExecutor(), metadataService: metadata)
        model.database = "db"; model.sql = "SELECT id,name FROM t"
        let request = try #require(model.execute())
        await metadata.waitUntilWaiting()
        let identity = model.resultID
        #expect(model.isLoadingEditing); #expect(model.result != nil)
        model.setBackgrounded(true)
        await metadata.release(); await request.value
        #expect(model.editing == nil); #expect(!model.isLoadingEditing)
        #expect(model.editingMessage?.contains("暂停") == true)
        model.setBackgrounded(false); #expect(model.resultID == identity)
        await model.execute()?.value
        #expect(model.editing != nil); #expect(model.editingMessage == nil)
    }

    @Test func actualConnectionFailureRetainsResultsAndFreshManualRequestRecovers() async throws {
        let executor = ReliabilityQuery(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        model.sql = "SELECT id,name FROM t"; model.database = "db"
        await model.execute()?.value
        let identity = model.resultID
        await executor.failNext()
        await model.execute()?.value
        #expect(model.resultID == identity); #expect(model.result?.rows == [["1", "before"]])
        #expect(model.errorMessage?.contains("顶部刷新") == true); #expect(!model.isLoading)
        #expect(await executor.calls == 2)
        await model.execute()?.value
        #expect(model.resultID != identity); #expect(model.errorMessage == nil)
        #expect(await executor.calls == 3)
    }

    @Test func backgroundDoesNotEraseCompletedExportOrReplayGeneration() async throws {
        let data = MobileGridData(preview: .init(result: .init(columns: ["id"], rows: [["1"]])))
        let model = MobileDataExportModel(snapshot: .init(data: data, name: "owned", scopeDescription: "loaded"))
        model.format = .json
        await model.prepare()?.value
        let file = try #require(model.file)
        defer { model.cancel() }
        model.setBackgrounded(true)
        #expect(model.file?.id == file.id); #expect(FileManager.default.fileExists(atPath: file.url.path))
        #expect(!model.canPrepare); #expect(model.prepare() == nil)
        model.setBackgrounded(false)
        #expect(model.file?.id == file.id); #expect(!model.isExporting)
    }
}

private actor ReliabilityBrowser: MobileMySQLServicing {
    private var hold = false, waiting = false, fails = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var pageCalls = 0
    func holdNext() { hold = true }
    func failHeld() { fails = true; release() }
    func waitForHeldRequest() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func databases(configuration: MariaDBTransportConfiguration) async throws -> [String] { ["db"] }
    func objects(configuration: MariaDBTransportConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        .init(objects: [.init(database: database, name: "t", kind: .table, comment: "")], hasMore: false)
    }
    func columns(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        [.init(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: ""),
         .init(name: "name", type: "varchar(80)", isNullable: true, key: "", defaultValue: nil, extra: "", comment: "")]
    }
    func page(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        pageCalls += 1
        if hold { hold = false; waiting = true; await withCheckedContinuation { continuation = $0 } }
        if fails { fails = false; throw CocoaError(.fileReadUnknown) }
        // Intentionally ignores cancellation: the model must reject late responses.
        return .init(object: object, preview: .init(result: .init(columns: ["id", "name"], rows: [["1", "before"]])), columns: columns,
            offset: offset, pageSize: size, hasNextPage: true, hasStableOrder: true)
    }
}

private actor ReliabilityQuery: MobileQueryExecuting {
    private var hold = false, waiting = false, fail = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func holdNext() { hold = true }
    func failNext() { fail = true }
    func waitForHeldRequest() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        calls += 1
        if hold { hold = false; waiting = true; await withCheckedContinuation { continuation = $0 } }
        if fail {
            fail = false
            return try await MobileMariaDBExecutor().execute(configuration: .init(host: "127.0.0.1", port: 1,
                username: "unused", password: nil, database: nil, tlsMode: .disabled), sql: "SELECT 1")
        }
        return try await QueryEditingExecutor().execute(configuration: configuration, sql: sql)
    }
}

private struct ReliabilityUnknownWriter: MobileDataMutating {
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MariaDBTransportConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws {
        try await authorize(); throw MobileDataMutationError.uncertainCommit
    }
}
private actor ReliabilityExportWriter: MobileDataExportWriting {
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func export(_ request: WorkspaceDataExportRequest, to destination: URL,
                progress: @escaping WorkspaceDataExporter.ProgressHandler) async throws -> Int {
        calls += 1
        try Data("partial".utf8).write(to: destination)
        if calls == 1 { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return 1 // Deliberately returns after cancellation to check generation fencing.
    }
}

private actor ReliabilityConfirmedWriter: MobileDataMutating {
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MariaDBTransportConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws {
        try await authorize()
        waiting = true; await withCheckedContinuation { continuation = $0 }
        // Acknowledged commit followed by close is allowed to finish after cancellation.
    }
}
