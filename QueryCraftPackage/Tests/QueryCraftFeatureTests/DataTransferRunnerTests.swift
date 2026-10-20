import Foundation
import Testing
@testable import QueryCraftFeature

struct DataTransferRunnerTests {
    private func fixture(strategy: TransferStrategy = .append, failInsert: Int? = nil, failCommit: Bool = false, native: Bool = false, streaming: Bool = false) async throws -> (DataTransferPlan, DataTransferCatalog, TransferTestFactory) {
        let factory = TransferTestFactory(failInsert: failInsert, failCommit: failCommit, native: native, streaming: streaming)
        let catalog = DataTransferCatalog(factory: factory)
        var config = DataTransferConfiguration()
        config.source = .init(profileID: UUID(), database: "source")
        config.target = .init(profileID: UUID(), database: "target")
        config.objects = [.init(kind: .table, name: "table.with.dot")]
        config.content = .dataOnly; config.strategy = strategy; config.batchSize = 100
        let source = TransferConnection(endpoint: config.source, configuration: .init(host: "localhost", port: 3306, username: "test", password: nil, database: "source", tlsMode: .disabled))
        let target = TransferConnection(endpoint: config.target, configuration: source.configuration.selecting(database: "target"))
        let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: config, source: source, target: target)
        return (plan, catalog, factory)
    }

    @Test("Disabled native loading still uses one streaming read with batched INSERT", arguments: [TransferStrategy.append, .upsert, .overwrite])
    func streamingFallback(strategy: TransferStrategy) async throws {
        let (plan, catalog, factory) = try await fixture(strategy: strategy, streaming: true)
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .completed)
        let reads = await factory.log.queries.filter { $0.0 == "source" && $0.1.hasPrefix("SELECT `id`, `value` FROM") }
        #expect(reads.count == 1)
        #expect(reads.first?.1.contains("LIMIT") == false)
        #expect(reads.first?.1.contains("ORDER BY") == true)
        #expect(await factory.log.insertCount == 3)
        #expect(await factory.log.nativeLoads == 0)
    }

    @Test("Streamed INSERT failures roll back without retry")
    func streamingFailure() async throws {
        let (plan, catalog, factory) = try await fixture(failInsert: 2, streaming: true)
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .failed)
        #expect(await factory.log.insertCount == 2)
        #expect(await factory.log.queries.contains { $0.0 == "target" && $0.1 == "ROLLBACK" })
    }

    @Test("Streamed INSERT cancellation retains its read count and confirms rollback")
    func streamingCancellation() async throws {
        let (plan, catalog, factory) = try await fixture(streaming: true)
        let task = Task {
            await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { item in
                if item.readRows > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }, backups: { _ in })
        }
        #expect(await task.value.0 == .cancelled)
        #expect(await factory.log.rollbackCancelled == false)
        #expect(await factory.log.queries.contains { $0.0 == "target" && $0.1 == "ROLLBACK" })
    }

    @Test("One native stream per table validates counts before committing", arguments: [TransferStrategy.append, .overwrite])
    func nativeTransfer(strategy: TransferStrategy) async throws {
        let (plan, catalog, factory) = try await fixture(strategy: strategy, native: true)
        let recorder = TransferProgressRecorder()
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { await recorder.receive($0) }, backups: { _ in })
        #expect(result.0 == .completed)
        #expect(await factory.log.nativeLoads == 1)
        #expect(await factory.log.queries.allSatisfy { !$0.1.hasPrefix("INSERT INTO") })
        #expect(await recorder.latest?.committedRows == 203)
        #expect(await recorder.latest?.message.contains("LOAD DATA") == true)
    }

    @Test("Native failures and count mismatches roll back without retrying INSERT", arguments: [false, true])
    func nativeFailure(mismatch: Bool) async throws {
        let (plan, catalog, factory) = try await fixture(native: true)
        await factory.log.setNativeFailure(mismatch: mismatch)
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .failed)
        let queries = await factory.log.queries
        #expect(queries.contains { $0.0 == "target" && $0.1 == "ROLLBACK" })
        #expect(!queries.contains { $0.1.hasPrefix("INSERT INTO") || $0.1 == "COMMIT" })
        #expect(await factory.log.nativeLoads == 1)
    }

    @Test("Native Upsert stages rows and retains the configured merge batches")
    func nativeUpsertStaging() async throws {
        let (plan, catalog, factory) = try await fixture(strategy: .upsert, native: true)
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .completed)
        #expect(await factory.log.nativeLoads == 1)
        #expect(await factory.log.insertCount == 3)
        #expect(await factory.log.queries.contains { $0.1.hasPrefix("CREATE TEMPORARY TABLE") && $0.1.contains("PRIMARY KEY") })
        #expect(await factory.log.queries.filter { $0.1.hasPrefix("INSERT INTO") }.allSatisfy { $0.1.contains(" SELECT ") && $0.1.contains("ORDER BY") && $0.1.contains("ON DUPLICATE KEY UPDATE") })
    }

    @Test("Unavailable staging restores its savepoint before starting ordinary Upsert")
    func deniedStaging() async throws {
        let (plan, catalog, factory) = try await fixture(strategy: .upsert, native: true)
        await factory.log.setStagingDenied()
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .completed)
        #expect(await factory.log.nativeLoads == 0)
        #expect(await factory.log.insertCount == 3)
        let queries = await factory.log.queries
        let restore = try #require(queries.firstIndex { $0.1.hasPrefix("ROLLBACK TO SAVEPOINT") })
        let insert = try #require(queries.firstIndex { $0.1.hasPrefix("INSERT INTO") })
        #expect(restore < insert)
        #expect(queries.contains { $0.1 == "COMMIT" })
    }

    @Test("Paged transfers use a source snapshot, exact batches and confirmed commits", arguments: [TransferStrategy.append, .overwrite, .upsert])
    func transfers(strategy: TransferStrategy) async throws {
        let (plan, catalog, factory) = try await fixture(strategy: strategy)
        let recorder = TransferProgressRecorder()
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { await recorder.receive($0) }, backups: { _ in })
        #expect(result.0 == .completed)
        let queries = await factory.log.queries
        #expect(queries.contains { $0.0 == "source" && $0.1 == "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY" })
        #expect(queries.filter { $0.0 == "target" && $0.1.hasPrefix("INSERT INTO") }.count == 3)
        #expect(queries.contains { $0.0 == "target" && $0.1 == "COMMIT" })
        #expect(queries.contains { $0.0 == "target" && $0.1.hasPrefix("DELETE FROM") } == (strategy == .overwrite))
        #expect(await recorder.latest?.committedRows == 203)
        #expect(await recorder.latest?.status == .completed)
        let reads = queries.filter { $0.0 == "source" && $0.1.hasPrefix("SELECT `id`, `value` FROM") }.map(\.1)
        #expect(reads.count == 3)
        #expect(reads.allSatisfy { !$0.contains("OFFSET") })
        #expect(reads[1].contains("`id` > 99"))
        #expect(reads[2].contains("`id` > 199"))
    }

    @Test("Failed batches roll back without automatically retrying writes", arguments: [TransferStrategy.append, .overwrite])
    func rollback(strategy: TransferStrategy) async throws {
        let (plan, catalog, factory) = try await fixture(strategy: strategy, failInsert: 2)
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .failed)
        let queries = await factory.log.queries
        #expect(queries.filter { $0.0 == "target" && $0.1.hasPrefix("INSERT INTO") }.count == 2)
        #expect(queries.contains { $0.0 == "target" && $0.1 == "ROLLBACK" })
        #expect(!queries.contains { $0.0 == "target" && $0.1 == "COMMIT" })
    }

    @Test("Lost commit acknowledgement is uncertain and never retried")
    func uncertain() async throws {
        let (plan, catalog, factory) = try await fixture(failCommit: true)
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .uncertain)
        let queries = await factory.log.queries
        #expect(queries.filter { $0.0 == "target" && $0.1 == "COMMIT" }.count == 1)
        #expect(!queries.contains { $0.0 == "target" && $0.1 == "ROLLBACK" })
    }

    @Test("Cancellation after a read batch rolls back the current table")
    func cancellation() async throws {
        let (plan, catalog, factory) = try await fixture()
        let task = Task {
            await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { item in
                if item.readRows > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }, backups: { _ in })
        }
        let result = await task.value
        #expect(result.0 == .cancelled)
        let queries = await factory.log.queries
        #expect(queries.contains { $0.0 == "target" && $0.1 == "ROLLBACK" })
        #expect(!queries.contains { $0.0 == "target" && $0.1 == "COMMIT" })
        #expect(await factory.log.rollbackCancelled == false)
    }

    @Test("Schema changes between preview and execution stop all writes")
    func stalePlan() async throws {
        let (plan, catalog, factory) = try await fixture()
        await factory.log.changeSchema()
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .failed)
        #expect(await factory.log.queries.allSatisfy { !$0.1.hasPrefix("INSERT") && !$0.1.hasPrefix("DELETE") })
    }

    @Test("Execution authorization failure stops before opening or writing")
    func authorizationFailure() async throws {
        let (plan, catalog, factory) = try await fixture()
        await factory.log.clear()
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: { throw TransferFailure("执行授权失败", "Execution authorization failed") }, progress: { _ in }, backups: { _ in })
        #expect(result.0 == .failed)
        #expect(await factory.log.queries.isEmpty)
    }

    @Test("Different connection aliases of the same physical namespace are rejected")
    func aliases() async throws {
        let (plan, catalog, factory) = try await fixture()
        var config = plan.configuration; config.source.database = config.target.database
        let source = TransferConnection(endpoint: config.source, configuration: .init(host: "server-alias", port: 3306, username: "test", password: nil, database: config.source.database, tlsMode: .disabled))
        await #expect(throws: (any Error).self) {
            try await DataTransferPlanner(catalog: catalog).prepare(configuration: config, source: source, target: plan.target)
        }
        #expect(await factory.log.queries.allSatisfy { !$0.1.hasPrefix("INSERT") && !$0.1.hasPrefix("RENAME") })
    }

    @Test("Successful empty source is reported as zero rows without an INSERT")
    func empty() async throws {
        let (plan, catalog, factory) = try await fixture()
        await factory.log.setRowCount(0)
        let recorder = TransferProgressRecorder()
        let result = await DataTransferRunner(catalog: catalog).run(plan, authorize: {}, progress: { await recorder.receive($0) }, backups: { _ in })
        #expect(result.0 == .completed)
        #expect(await recorder.latest?.committedRows == 0)
        #expect(await factory.log.queries.allSatisfy { !$0.1.hasPrefix("INSERT") })
    }

    @Test("Reviewed transfers start directly without an additional lock")
    @MainActor func startsDirectly() async throws {
        let (plan, catalog, _) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DataTransferManager(historyURL: root.appending(path: "history.json"), runner: .init(catalog: catalog))
        try manager.start(plan, name: "direct", sourceLabel: "s", targetLabel: "t")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while manager.hasActiveRuns && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!manager.hasActiveRuns)
        #expect(manager.runs.first?.status == .completed)
        #expect(manager.runs.first?.committedRows == 203)
    }

    @Test("Concurrent tasks reserve physical target objects even across saved profiles")
    @MainActor func reservations() async throws {
        let (first, catalog, _) = try await fixture()
        let (second, _, _) = try await fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DataTransferManager(historyURL: root.appending(path: "history.json"), runner: .init(catalog: catalog))
        try manager.start(first, name: "first", sourceLabel: "s", targetLabel: "t")
        #expect(throws: (any Error).self) { try manager.start(second, name: "second", sourceLabel: "s", targetLabel: "t") }
        await manager.cancelAllAndWait()
        #expect(!manager.hasActiveRuns)
    }
}

private actor TransferProgressRecorder {
    var latest: TransferItemProgress?
    func receive(_ item: TransferItemProgress) { latest = item }
}

actor TransferTestLog {
    var queries: [(String, String)] = []
    var changed = false
    var insertCount = 0
    var rollbackCancelled = false
    var failLoading = false
    var emptyCatalog = false
    var sourceRowCount = 203
    var nativeLoads = 0
    var nativeFailure: Bool?
    var stagingDenied = false
    func setStagingDenied() { stagingDenied = true }
    func setNativeFailure(mismatch: Bool) { nativeFailure = mismatch }
    func startNative() { nativeLoads += 1 }
    func append(_ sql: String, database: String) { queries.append((database, sql)); if sql.hasPrefix("INSERT") { insertCount += 1 }; if sql == "ROLLBACK" { rollbackCancelled = Task.isCancelled } }
    func changeSchema() { changed = true }
    func clear() { queries = [] }
    func setLoadingFailure(_ value: Bool) { failLoading = value }
    func setEmptyCatalog(_ value: Bool) { emptyCatalog = value }
    func setRowCount(_ value: Int) { sourceRowCount = value }
}

actor TransferTestGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !entered else { return }
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { resume = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { resume?.resume(); resume = nil }
}

struct TransferTestFactory: WorkspaceSessionFactory {
    let log = TransferTestLog()
    let failInsert: Int?
    let failCommit: Bool
    var native = false
    var streaming = false
    var gate: TransferTestGate? = nil
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession {
        let session = TransferTestSession(database: configuration.database ?? "", log: log, failInsert: failInsert, failCommit: failCommit, gate: gate, native: native)
        if streaming && configuration.database == "source" { return TransferStreamingTestSession(base: session, log: log) }
        return session
    }
}

private actor TransferStreamingTestSession: WorkspaceSession, WorkspaceNativeRowSourceSession {
    let base: any WorkspaceSession
    let log: TransferTestLog
    init(base: any WorkspaceSession, log: TransferTestLog) { self.base = base; self.log = log }
    func connect() async throws { try await base.connect() }
    func close() async { await base.close() }
    func isConnected() async -> Bool { await base.isConnected() }
    func fetchDatabases() async throws -> [String] { try await base.fetchDatabases() }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { try await base.fetchObjects(in: database) }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { try await base.fetchDetails(for: object, in: database) }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { try await base.fetchIndexes(for: object, in: database) }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { try await base.fetchDataCount(for: object, in: database) }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult {
        try await base.fetchDataPage(for: object, in: database, offset: offset, limit: limit, sort: sort, onBatch: onBatch)
    }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        try await base.executeStatement(sql, kind: kind, database: database, onBatch: onBatch)
    }
    func streamTransferRows(sql: String, batchSize: Int, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> Int {
        await log.append(sql, database: "source")
        let total = await log.sourceRowCount
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "id"), .init(id: 1, name: "value")]
        for start in stride(from: 0, to: total, by: batchSize) {
            try Task.checkCancellation()
            let rows = (start..<min(start + batchSize, total)).map { WorkspaceDatabaseDataRow(id: $0, values: [.text(String($0)), .text("中文🙂 \($0)")]) }
            try await onBatch(.init(columns: columns, rows: rows))
        }
        if total == 0 { try await onBatch(.init(columns: columns, rows: [])) }
        try Task.checkCancellation(); return total
    }
}

private actor TransferTestSession: WorkspaceSession, WorkspaceNativeBulkTransferSession {
    let database: String
    let log: TransferTestLog
    let failInsert: Int?
    let failCommit: Bool
    let gate: TransferTestGate?
    let native: Bool
    var connected = false
    init(database: String, log: TransferTestLog, failInsert: Int?, failCommit: Bool, gate: TransferTestGate?, native: Bool) { self.database = database; self.log = log; self.failInsert = failInsert; self.failCommit = failCommit; self.gate = gate; self.native = native }
    func nativeBulkTransferFormat() -> WorkspaceNativeBulkFormat? { native && database == "target" ? .mysqlLocalTSV : nil }
    func executeNativeBulkTransfer(sql: String, token: String, stream: WorkspaceNativeBulkStream) async throws -> Int {
        await log.startNative()
        if await log.nativeFailure == false { throw WorkspaceNativeBulkError.invalidLocalRequest }
        let data = try await consumeNativeStream(stream)
        let rows = data.filter { $0 == 10 }.count
        return rows + (await log.nativeFailure == true ? 1 : 0)
    }
    func connect() { connected = true }
    func close() { connected = false }
    func isConnected() -> Bool { connected }
    func connectionID() -> Int { 1 }
    func fetchDatabases() async throws -> [String] {
        await gate?.pause()
        if await log.failLoading { throw TransferFailure("模拟元数据请求失败", "Simulated metadata failure") }
        return ["source", "target"]
    }
    func fetchObjects(in database: String) -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) -> WorkspaceDatabaseObjectDetails { .init(columns: [], ddl: "") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) -> Int { 0 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) -> WorkspaceDatabaseDataFetchResult { .init(columns: [], hasNextPage: false) }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        await log.append(sql, database: self.database)
        if sql.hasPrefix("CREATE TEMPORARY TABLE"), await log.stagingDenied { throw TransferFailure("没有临时表权限", "Temporary tables are not permitted") }
        if sql == "COMMIT" && failCommit { throw WorkspaceSessionError.notConnected }
        if sql.hasPrefix("INSERT INTO"), let failInsert, await log.insertCount == failInsert { throw TransferFailure("模拟写入失败", "Simulated write failure") }
        let names: [String], values: [[String?]]
        if sql.contains("@@server_uuid") { names = ["identity"]; values = [["same-test-server"]] }
        else if sql.contains("@@SESSION.sql_mode") && sql.hasPrefix("SELECT") { names = ["mode"]; values = [["STRICT_ALL_TABLES"]] }
        else if sql.contains("@@max_allowed_packet") { names = ["packet"]; values = [["16777216"]] }
        else if sql.contains("SELECT ENGINE") { names = ["engine"]; values = [["InnoDB"]] }
        else if sql.contains("information_schema.COLUMNS") {
            names = ["name", "type", "nullable", "key", "default_value", "extra", "comment", "generation"]
            values = [["id", await log.changed ? "bigint" : "int", "NO", "PRI", nil, "", "", ""], ["value", "text", "YES", "", nil, "", "", ""]]
        } else if sql.contains("information_schema.TABLES") { names = ["name", "kind"]; values = await log.emptyCatalog ? [] : [["table.with.dot", "BASE TABLE"]] }
        else if sql.hasPrefix("SELECT `id`, `value` FROM") {
            names = ["id", "value"]
            let offset: Int
            if let cursor = sql.range(of: #"`id` > ([0-9]+)"#, options: .regularExpression) {
                offset = (Int(sql[cursor].components(separatedBy: " > ").last ?? "0") ?? 0) + 1
            } else { offset = Int(sql.components(separatedBy: " OFFSET ").last ?? "0") ?? 0 }
            let count = await log.sourceRowCount
            values = offset >= count ? [] : (offset..<min(offset + 100, count)).map { [String($0), "中文🙂 \($0)"] }
        } else { names = []; values = [] }
        let columns = names.enumerated().map { WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element) }
        if !names.isEmpty { try await onBatch(.init(columns: columns, rows: values.enumerated().map { index, values in .init(id: index, values: values.map { $0.map(WorkspaceDatabaseDataCell.text) ?? .null }) })) }
        return .init(columns: columns, rowCount: values.count)
    }
}
