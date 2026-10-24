import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

enum MobileSQLSessionError: LocalizedError {
    case busy, locked, cacheBudget, uncertain, staleConfirmation
    var errorDescription: String? {
        switch self {
        case .busy: "SQL 会话正在执行或清理，请稍候。"
        case .locked: "安全锁已启用，无法执行写 SQL。"
        case .cacheBudget: "整批查询缓存达到 256 MiB 上限，读取已停止；已缓存的部分结果仍可查看。"
        case .uncertain: "连接中断，写入或提交结果尚待核实。请核对服务器数据；不要直接重试写入。"
        case .staleConfirmation: "SQL 或连接已变更，请重新执行并确认。"
        }
    }
}

/// The store is the same implementation as macOS. Only the visible mobile
/// window is materialized; exports read the complete cache in bounded batches.
actor MobileCachedQueryResult {
    nonisolated let store: WorkspaceQueryResultStore
    private(set) var columns: [WorkspaceDatabaseDataColumn] = []
    private(set) var hasBinaryValues = false
    private var columnDetails: [String]?
    private let budget: MobileSQLCacheBudget
    init(budget: MobileSQLCacheBudget = .init()) throws {
        self.budget = budget
        store = try .init(maximumResidentRowCount: 0, pageSize: 1, maximumCachedPages: 2)
    }
    func append(_ batch: WorkspaceDatabaseDataBatch) async throws {
        try Task.checkCancellation()
        // Charge encoded payloads, not just text bytes: JSON escaping and row
        // metadata must count against the batch budget as well.
        let encoder = JSONEncoder()
        let bytes = try batch.rows.reduce(0) { try $0 + encoder.encode($1).count + 64 }
        try await budget.reserve(bytes)
        columns = batch.columns
        hasBinaryValues = hasBinaryValues || batch.rows.contains { $0.values.contains { if case .binary = $0 { true } else { false } } }
        try await store.append(batch.rows)
    }
    func finish(_ summary: MobileSQLStreamResult) {
        columns = summary.columns; columnDetails = summary.columnDetails
    }
    func page(offset: Int, summary: MobileSQLStreamResult? = nil) async throws -> MobileSQLPreview {
        let end = min(offset + 500, store.rowCount)
        let rows = try await store.loadRows(in: offset..<max(offset, end), maximumBytes: 4_194_304)
        let metadata = summary?.columns ?? columns
        var preview = MobileSQLPreview(result: .init(columns: metadata.map(\.name), columnTypes: metadata.map(\.type),
            columnOrigins: metadata.map { column in column.origin.flatMap { origin in
                origin.databaseName.map { .init(databaseName: $0, tableName: origin.tableName, columnName: origin.columnName) }
            } }, rows: rows.map { $0.values.map { cell in
                switch cell { case .null: nil; case let .text(text): text; case let .binary(count, _): "BINARY (\(count) bytes)" }
            } }, affectedRows: summary?.affectedRows ?? 0, insertID: summary?.insertID ?? 0), cells: rows.map(\.values), metadata: metadata)
        preview.columnDetails = summary?.columnDetails ?? columnDetails
        return preview
    }
}

actor MobileSQLCacheBudget {
    static let maximumBytes = 268_435_456
    private var bytes = 0
    func reserve(_ additional: Int) throws {
        guard additional <= Self.maximumBytes - bytes else { throw MobileSQLSessionError.cacheBudget }
        bytes += additional
    }
}

enum MobileSQLSessionEvent: Sendable {
    case started(Int)
    case progress(Int, MobileCachedQueryResult, MobileSQLPreview, Int)
    case completed(Int, MobileCachedQueryResult, MobileSQLPreview, MobileSQLStreamResult, WorkspaceQueryTransactionState, Bool)
}

actor MobileSQLSession {
    private var client: (any MobileSQLSessionConnection)?
    private let makeConnection: @Sendable (MobileSQLConfiguration) throws -> any MobileSQLSessionConnection
    init(makeConnection: @escaping @Sendable (MobileSQLConfiguration) throws -> any MobileSQLSessionConnection = { configuration in
        switch configuration.driver {
        case .mysql: return MobileMySQLSessionConnection(configuration: configuration)
        case .postgresql: return MobilePostgreSQLSessionConnection(configuration: configuration)
        default: throw MobileQueryError.readOnlySQLRequired
        }
    }) { self.makeConnection = makeConnection }
    private var configuration: MobileSQLConfiguration?
    private var busy = false
    private var closingCount = 0
    private var closing: Bool { closingCount > 0 }
    private var generation = UUID()
    private(set) var state: WorkspaceQueryTransactionState = .disconnected

    func disconnect() async {
        generation = UUID()
        closingCount += 1
        defer { closingCount -= 1 }
        // close is serialized behind the current wire operation. Closing the
        // socket rolls back any uncommitted transaction; never send COMMIT here.
        let client = client
        self.client = nil; configuration = nil; state = .disconnected
        await client?.close()
    }

    func run(configuration: MobileSQLConfiguration, statements: [SQLExecutionStatement],
             authorize: @escaping @Sendable (SQLStatementKind) async throws -> Void,
             receive: @escaping @Sendable (MobileSQLSessionEvent) async throws -> Void) async throws {
        guard !busy, !closing else { throw MobileSQLSessionError.busy }
        busy = true
        defer { busy = false }
        guard !statements.isEmpty, statements.count <= MobileQueryBatchLimits.maximumStatements else { throw MobileQueryBatchError.tooManyStatements }
        var sentKind: SQLStatementKind?
        let budget = MobileSQLCacheBudget()
        do {
            if self.configuration != configuration || client == nil {
                await disconnect()
                try Task.checkCancellation()
                let connection = try makeConnection(configuration)
                client = connection; self.configuration = configuration
                try await connection.connect(); state = .autoCommit
            }
            let generation = self.generation
            guard let client else { throw WorkspaceSessionError.notConnected }
            // Validate the entire immutable batch before sending any statement.
            for statement in statements {
                guard !statement.sql.utf8.contains(0) else { throw MobileSQLSessionError.staleConfirmation }
                _ = try WorkspaceReadOnlyQueryValidator.validate(statement.sql, policy: statement.kind.requiresWriteAccess ? .writesAllowed : .readOnly)
                try await authorize(statement.kind)
            }
            for statement in statements {
                try Task.checkCancellation()
                guard !closing, self.generation == generation else { throw CancellationError() }
                try await receive(.started(statement.index))
                let cache = try MobileCachedQueryResult(budget: budget)
                let guardedRead = statement.kind == .read && state == .autoCommit
                if guardedRead { try await client.query("START TRANSACTION READ ONLY") }
                try await authorize(statement.kind)
                try Task.checkCancellation()
                guard !closing, self.generation == generation else { throw CancellationError() }
                sentKind = statement.kind
                let summary = try await client.queryStream(statement.sql) { batch in
                    try await cache.append(batch)
                    let count = cache.store.rowCount
                    // Publish a bounded first page, then counts at batch boundaries.
                    let page = try await cache.page(offset: 0)
                    try await receive(.progress(statement.index, cache, page, count))
                }
                sentKind = nil
                state = summary.transactionState
                if guardedRead {
                    try await client.query("ROLLBACK")
                    state = .autoCommit
                }
                await cache.finish(summary)
                let page = try await cache.page(offset: 0, summary: summary)
                let binary = await cache.hasBinaryValues
                try await receive(.completed(statement.index, cache, page, summary, state, binary))
            }
        } catch {
            let knownRejection = client?.isDefiniteRejection(error) ?? false
            let uncertain = !knownRejection && sentKind.map { $0.requiresWriteAccess || $0 == .transaction(.commit) } == true
            await disconnect()
            if uncertain { throw MobileSQLSessionError.uncertain }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
