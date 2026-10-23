import Foundation
import Observation
import QueryCraftMobileCore
import QueryCraftMobileTransport

@MainActor @Observable
final class MobileQueryModel {
    var host = "127.0.0.1" { didSet { if !restoringConfiguration, oldValue != host { if protectPendingChanges() { restoreConfiguration { host = oldValue } } else { configurationChanged() } } } }
    var port = "3306" { didSet { if !restoringConfiguration, oldValue != port { if protectPendingChanges() { restoreConfiguration { port = oldValue } } else { configurationChanged() } } } }
    var username = "root" { didSet { if !restoringConfiguration, oldValue != username { if protectPendingChanges() { restoreConfiguration { username = oldValue } } else { configurationChanged() } } } }
    var password = "" { didSet { if !restoringConfiguration, oldValue != password { if protectPendingChanges() { restoreConfiguration { password = oldValue } } else { configurationChanged() } } } }
    var database = "" { didSet { if !restoringConfiguration, oldValue != database { if protectPendingChanges() { restoreConfiguration { database = oldValue } } else { configurationChanged() } } } }
    var tlsMode: ConnectionTLSMode = .required { didSet { if !restoringConfiguration, oldValue != tlsMode { if protectPendingChanges() { restoreConfiguration { tlsMode = oldValue } } else { configurationChanged() } } } }
    var sql = "SELECT VERSION() AS server_version, '你好 iPad' AS greeting, NULL AS nullable_value;" {
        didSet {
            if oldValue != sql {
                sourceRevision &+= 1
                let length = sql.utf16.count, range = executionInput.selection
                let location = range.location == NSNotFound ? 0 : max(0, min(range.location, length))
                executionInput.selection = .init(location: location, length: min(max(0, range.length), length - location))
            }
        }
    }
    let executionInput = MobileSQLExecutionInput()
    @ObservationIgnored private var sourceRevision: UInt64 = 0
    @ObservationIgnored private var retrySQL: String?
    private var displayed = MobileQueryResultState()
    var sqlConfirmation: MobileSQLConfirmation?
    private(set) var transactionState: WorkspaceQueryTransactionState = .disconnected
    private(set) var writeOutcomeUncertain = false
    private var sqlWriteInFlight = false
    @ObservationIgnored private let sqlSession: MobileSQLSession?
    var blocksOtherWrites: Bool { sqlSession != nil && (isLoading || transactionState == .inTransaction || writeOutcomeUncertain) }
    var transactionTitle: String {
        if writeOutcomeUncertain { return "写入结果待核实" }
        switch transactionState { case .disconnected: return "未连接"; case .autoCommit: return "自动提交"; case .inTransaction: return "事务进行中" }
    }
    var cachedRowCount: Int { displayed.cache == nil ? (result?.rows.count ?? 0) : displayed.cachedRowCount }
    var cacheOffset: Int { displayed.cacheOffset }
    var hasCachePages: Bool { displayed.cache != nil && displayed.cachedRowCount > (result?.rows.count ?? 0) }
    var canPageCache: Bool { !isLoading && !isLoadingEditing && !hasPendingRowChanges && !requiresResultReload }
    var queryExportSnapshot: MobileDataExportSnapshot? {
        guard let preview else { return nil }
        var snapshot = MobileDataExportSnapshot(data: .init(preview: preview, details: columnDetails), name: "query-result",
            scopeDescription: displayed.cache == nil ? "当前查询结果" : "当前缓存页（最多 500 行）")
        if let cache = displayed.cache, displayed.cachedRowCount > 0, !requiresResultReload {
            let count = displayed.cachedRowCount
            snapshot.allRowsProvider = .init(estimatedRowCount: count, makeSource: { cache.store.makeDataExportRowSource(rows: .range(0...(count - 1)), maximumBatchBytes: 4_194_304) })
            snapshot.allRowsLabel = displayed.cacheComplete ? "全部查询缓存" : "已缓存的部分结果"
            snapshot.isQueryCache = true
            snapshot.hasBinaryColumns = displayed.hasBinaryValues
        }
        return snapshot
    }
    @discardableResult func pageCache(_ direction: Int) -> Task<Void, Never>? {
        guard canPageCache, let cache = displayed.cache else { return nil }
        let record = displayed, identity = requestID
        let offset = direction < 0 ? (record.previousCacheOffsets.last ?? 0) : record.cacheOffset + (record.result?.rows.count ?? 0)
        guard offset < record.cachedRowCount else { return nil }
        guard offset != record.cacheOffset else { return nil }
        isLoadingEditing = true
        return Task { [weak self] in
            do {
                let page = try await cache.page(offset: offset)
                guard let self, self.requestID == identity, self.displayed === record else { return }
                if direction < 0 { _ = record.previousCacheOffsets.popLast() } else { record.previousCacheOffsets.append(record.cacheOffset) }
                record.preview = page; record.result = page.result; record.cacheOffset = offset
                record.resultRevision = UUID(); record.editing = nil; record.editingPage = nil
                self.isLoadingEditing = false
            } catch {
                guard let self, self.requestID == identity else { return }
                self.isLoadingEditing = false; self.errorMessage = error.localizedDescription
            }
        }
    }
    @discardableResult func confirmSQL() -> Task<Void, Never>? {
        guard let confirmation = sqlConfirmation else { return nil }
        sqlConfirmation = nil
        guard confirmation.configuration == editorConfiguration, confirmation.sourceText == sql,
              confirmation.revision == sourceRevision, !isBackgrounded, !writeOutcomeUncertain else {
            errorMessage = MobileSQLSessionError.staleConfirmation.localizedDescription; return nil
        }
        if confirmation.requiresUnlock { safetyLock.disable() }
        return startExecution(capturedSQL: nil, approved: confirmation.statements)
    }
    @discardableResult func transaction(_ command: WorkspaceQueryTransactionCommand) -> Task<Void, Never>? {
        guard sqlSession != nil, !isLoading, !writeOutcomeUncertain else { return nil }
        if command == .begin, transactionState == .inTransaction { return nil }
        return startExecution(capturedSQL: command.sql, transactionCommand: true)
    }
    func acknowledgeUncertainOutcome() { guard !isLoading else { return }; writeOutcomeUncertain = false; safetyLock.enable() }
    func clearQueryResults() {
        guard !isLoading, !isLoadingEditing, !hasPendingRowChanges else { return }
        requestID = UUID(); retrySQL = nil; statementResults = []; displayed = MobileQueryResultState()
        status = "查询结果已清空"; errorMessage = nil
    }
    @discardableResult func disconnectSQL() -> Task<Void, Never>? {
        let running = task
        running?.cancel(); safetyLock.enable(); sqlConfirmation = nil
        guard let sqlSession else { cancel(); return nil }
        isLoading = true
        return Task { [weak self] in
            await sqlSession.disconnect()
            await running?.value
            guard let self else { return }
            self.transactionState = .disconnected
            self.isLoading = false; self.sqlWriteInFlight = false
            self.status = self.writeOutcomeUncertain ? MobileSQLSessionError.uncertain.localizedDescription : "SQL 会话已断开，未提交事务已回滚"
        }
    }
    private(set) var statementResults: [MobileQueryResultState] = []
    @ObservationIgnored var didExecute: ((String, String) -> Void)?
    @ObservationIgnored var didExecuteWrite: (() -> Void)?
    @ObservationIgnored private var activeBatch: [MobileQueryResultState] = []
    @ObservationIgnored private var activeStatementIndex: Int?
    var selectedResultID: UUID { displayed.id }
    var resultViewport: MobileGridViewport { displayed.viewport }
    var hasSubmittingChanges: Bool { allResults.contains { $0.editing?.isSubmitting == true } }
    private var allResults: [MobileQueryResultState] { statementResults.contains(where: { $0 === displayed }) ? statementResults : statementResults + [displayed] }
    func hasPendingChanges(for object: MobileDatabaseObject) -> Bool {
        allResults.contains { $0.editing?.object.editingSelection == object.editingSelection && ($0.editing?.hasChanges == true || $0.editing?.isSubmitting == true) }
    }
    private(set) var lastExecutedRange: SQLSourceRange? {
        get { displayed.lastExecutedRange }
        set { displayed.lastExecutedRange = newValue }
    }
    private(set) var result: CDatabaseQueryResult? {
        get { displayed.result }
        set { displayed.result = newValue }
    }
    private(set) var preview: CDatabaseQueryPreview? {
        get { displayed.preview }
        set { displayed.preview = newValue }
    }
    private(set) var lastExecutedSQL: String? {
        get { displayed.lastExecutedSQL }
        set { displayed.lastExecutedSQL = newValue }
    }
    private(set) var lastExecutedDatabase: String? {
        get { displayed.lastExecutedDatabase }
        set { displayed.lastExecutedDatabase = newValue }
    }
    private(set) var elapsed: Duration? {
        get { displayed.elapsed }
        set { displayed.elapsed = newValue }
    }
    private(set) var isLoading = false
    private var queryErrorMessage: String?
    private var blockedByPendingChanges = false
    private(set) var errorMessage: String? {
        get {
            if blockedByPendingChanges, hasPendingChanges {
                return hasPendingRowChanges ? MobileDataMutationError.pendingChanges.localizedDescription : "请先提交或回滚 SQL 事务，并核对待确认的写入结果后再更改连接。"
            }
            return queryErrorMessage
        }
        set { queryErrorMessage = newValue; blockedByPendingChanges = false }
    }
    private(set) var status = "填写连接后执行 SQL"
    private(set) var resultRevision: UUID {
        get { displayed.resultRevision }
        set { displayed.resultRevision = newValue }
    }
    private(set) var resultID: UUID {
        get { displayed.resultID }
        set { displayed.resultID = newValue }
    }
    private(set) var schemaRevision = UUID()
    private(set) var editing: MobileTableChanges? {
        get { displayed.editing }
        set { displayed.editing = newValue }
    }
    private(set) var editingPage: MobileTableSnapshot? {
        get { displayed.editingPage }
        set { displayed.editingPage = newValue }
    }
    private(set) var editingMessage: String? {
        get { displayed.editingMessage }
        set { displayed.editingMessage = newValue }
    }
    private(set) var isLoadingEditing = false
    private(set) var lastExecutedConfiguration: MariaDBTransportConfiguration? {
        get { displayed.lastExecutedConfiguration }
        set { displayed.lastExecutedConfiguration = newValue }
    }
    private(set) var requiresResultReload: Bool {
        get { displayed.requiresResultReload }
        set { displayed.requiresResultReload = newValue }
    }
    private(set) var isBackgrounded = false
    @ObservationIgnored var allowsDataMutation: () -> Bool = { true }
    @ObservationIgnored var allowsSQLExecution: () -> Bool = { true }
    let safetyLock: WorkspaceSafetyLock
    @ObservationIgnored private var restoringConfiguration = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let executionPlanner: any MobileSQLExecutionPlanning
    @ObservationIgnored private let executor: any MobileQueryExecuting
    @ObservationIgnored private let metadataService: any MobileMySQLServicing
    @ObservationIgnored private let mutationService: any MobileDataMutating

    init(executor: any MobileQueryExecuting = MobileMariaDBExecutor(), metadataService: any MobileMySQLServicing = MobileMySQLService(),
         executionPlanner: any MobileSQLExecutionPlanning = MobileSQLExecutionPlanner(),
         mutationService: any MobileDataMutating = MobileDataMutationService(), safetyLock: WorkspaceSafetyLock = WorkspaceSafetyLock()) {
        self.executor = executor; self.executionPlanner = executionPlanner
        self.sqlSession = executor is MobileMariaDBExecutor ? MobileSQLSession() : nil
        self.metadataService = metadataService; self.mutationService = mutationService; self.safetyLock = safetyLock
    }

    private var hasPendingRowChanges: Bool { allResults.contains { $0.editing.map { $0.hasChanges || $0.isSubmitting } ?? false } }
    var hasPendingChanges: Bool { hasPendingRowChanges || sqlWriteInFlight || transactionState == .inTransaction || writeOutcomeUncertain }
    var displayData: MobileGridData {
        guard let editing, let editingPage else { return .init(preview: preview) }
        return editing.displayData(page: editingPage, details: columnDetails)
    }
    var columnDetails: [String] {
        guard let preview else { return [] }
        return preview.result.workspaceColumns.map { column in
            let metadata = editingPage?.columns.first { $0.name == column.origin?.columnName }
            return [metadata?.type ?? column.type ?? "", metadata?.comment ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private func restoreConfiguration(_ restore: () -> Void) {
        restoringConfiguration = true
        defer { restoringConfiguration = false }
        restore()
    }

    @discardableResult private func protectPendingChanges() -> Bool {
        guard hasPendingChanges else { return false }
        blockedByPendingChanges = true
        return true
    }

    var canExecute: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (Int(port).map { (1...65535).contains($0) } ?? false)
            && !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var editorConfiguration: MariaDBTransportConfiguration? {
        guard let port = Int(port), (1...65535).contains(port), !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, username: username,
                     password: password, database: database.isEmpty ? nil : database, tlsMode: tlsMode)
    }

    @discardableResult func execute() -> Task<Void, Never>? { startExecution(capturedSQL: nil) }
    @discardableResult func executeAll() -> Task<Void, Never>? { startExecution(capturedSQL: nil, wholeDocument: true) }

    /// The selected statement alone is refreshed, never the whole earlier batch.
    @discardableResult func refresh() -> Task<Void, Never>? {
        let captured: String?
        if displayed.isPreviousBatch { captured = retrySQL }
        else if let statement = displayed.statement { captured = statement.kind == .read ? statement.sql : nil }
        else { captured = sql }
        guard let captured else {
            errorMessage = "刷新只重新读取查询，不会重放写 SQL 或事务命令。请在编辑器中明确执行。"; return nil
        }
        // Always use the captured-read path, including before the first result.
        // A nil retry target must never fall back to executing the editor draft.
        return startExecution(capturedSQL: captured)
    }

    @discardableResult func selectResult(_ id: UUID) -> Bool {
        guard !isLoading, !isLoadingEditing, !hasSubmittingChanges,
              let result = statementResults.first(where: { $0.id == id }) else { return false }
        displayed = result
        retrySQL = result.statement?.sql
        errorMessage = result.errorMessage
        status = result.status
        return true
    }

    private func startExecution(capturedSQL: String?, wholeDocument: Bool = false, approved: [SQLExecutionStatement]? = nil, transactionCommand: Bool = false) -> Task<Void, Never>? {
        guard !isBackgrounded else { return nil }
        guard !hasPendingRowChanges, (capturedSQL != nil || canExecute), let configuration = editorConfiguration else {
            if hasPendingRowChanges { blockedByPendingChanges = true }; return nil
        }
        if sqlSession != nil, isLoading || writeOutcomeUncertain { return nil }
        guard allowsSQLExecution() else { errorMessage = "请先处理其他页面的待提交改动。"; return nil }
        let source = SQLSourceSnapshot(revision: .init(sourceRevision), text: self.sql)
        let selection: NSRange
        do {
            guard capturedSQL != nil || source.text.utf8.count <= 262_144 else { throw MobileSQLExecutionError.documentTooLarge }
            selection = capturedSQL == nil ? try executionInput.capture(text: source.text) : .init(location: 0, length: 0)
        } catch {
            retrySQL = nil; errorMessage = error.localizedDescription; status = "执行范围不可用"; return nil
        }
        cancelActiveBatch()
        task?.cancel()
        let id = UUID(), refreshTarget = capturedSQL == nil || displayed.isPreviousBatch || transactionCommand ? nil : displayed
        requestID = id
        let database = self.database, start = ContinuousClock.now
        isLoading = true; isLoadingEditing = false; errorMessage = nil
        status = capturedSQL == nil ? "正在确定执行语句…" : "正在刷新当前结果…"
        let executor = self.executor, planner = executionPlanner
        let request = Task { [weak self] in
            var started = false
            do {
                let statements: [SQLExecutionStatement]
                if let approved { statements = approved }
                else if let capturedSQL {
                    let captured = SQLSourceSnapshot(revision: .init(0), text: capturedSQL)
                    statements = try await planner.planDocument(source: captured).statements
                    guard transactionCommand || statements.allSatisfy({ $0.kind == .read }) else { throw MobileQueryError.readOnlySQLRequired }
                } else {
                    let plan = try await (wholeDocument ? planner.planDocument(source: source) : planner.plan(source: source, selection: selection))
                    try Task.checkCancellation()
                    guard let self, self.requestID == id else { return }
                    guard self.sourceRevision == source.revision.rawValue, self.sql == source.text,
                          self.executionInput.matches(text: source.text, selection: selection) else { throw SQLExecutionTargetError.sourceChanged }
                    statements = plan.statements
                }
                guard let self, self.requestID == id else { return }
                if self.sqlSession != nil {
                    guard !statements.isEmpty, statements.count <= MobileQueryBatchLimits.maximumStatements else { throw MobileQueryBatchError.tooManyStatements }
                    if approved == nil, statements.contains(where: { ($0.kind.requiresWriteAccess && self.safetyLock.isEnabled) || $0.kind.requiresDangerousSQLConfirmation }) {
                        self.sqlConfirmation = .init(statements: statements, configuration: configuration,
                            sourceText: source.text, revision: source.revision.rawValue,
                            requiresUnlock: self.safetyLock.isEnabled && statements.contains { $0.kind.requiresWriteAccess })
                        self.isLoading = false; self.task = nil; self.status = "请核对 SQL 并确认执行"; return
                    }
                } else { try MobileQueryBatchLimits.validate(statements) }
                let records: [MobileQueryResultState]
                if let refreshTarget {
                    records = [refreshTarget]
                    refreshTarget.phase = .running
                } else {
                    records = statements.map { MobileQueryResultState(statement: $0) }
                    // Retain the visible old data while reading. It is explicitly
                    // labelled as the previous result, never as a new statement.
                    let previous = self.displayed.preview == nil ? nil : self.displayed
                    previous?.isPreviousBatch = true
                    self.statementResults = records + (previous.map { [$0] } ?? [])
                    self.displayed = previous ?? records[0]
                }
                self.activeBatch = records; self.activeStatementIndex = nil
                started = true
                if let session = self.sqlSession {
                    try await session.run(configuration: configuration, statements: statements,
                        authorize: { [weak self] kind in
                            guard let self else { throw CancellationError() }
                            try await self.authorizeSQL(kind, id: id, configuration: configuration)
                        }, receive: { [weak self] event in
                            guard let self else { throw CancellationError() }
                            try await self.acceptStream(event, records: records, id: id, configuration: configuration, database: database, start: start, refresh: refreshTarget != nil)
                        })
                } else if statements.count == 1 {
                    try await self.acceptBatch(.started(0), records: records, requestID: id, configuration: configuration,
                        database: database, start: start, refresh: refreshTarget != nil)
                    let preview = try await executor.preview(configuration: configuration, sql: statements[0].sql,
                        maximumRows: 500, maximumBytes: 4_194_304)
                    try Task.checkCancellation()
                    try await self.acceptBatch(.completed(0, preview), records: records, requestID: id, configuration: configuration,
                        database: database, start: start, refresh: refreshTarget != nil)
                } else {
                    try await executor.batch(configuration: configuration, statements: statements) { [weak self] event in
                        guard let self else { throw CancellationError() }
                        try await self.acceptBatch(event, records: records, requestID: id, configuration: configuration,
                            database: database, start: start, refresh: false)
                    }
                }
                if !records.allSatisfy({ $0.phase == .completed }) { try Task.checkCancellation() }
                guard self.requestID == id else { return }
                self.activeBatch = []; self.activeStatementIndex = nil
                self.sqlWriteInFlight = false
                self.isLoading = false; self.isLoadingEditing = false; self.task = nil
                self.errorMessage = self.displayed.errorMessage
                self.status = self.displayed.status
            } catch {
                guard let self, self.requestID == id else { return }
                self.isLoading = false; self.isLoadingEditing = false; self.task = nil
                self.sqlWriteInFlight = false
                if let session = self.sqlSession { self.transactionState = await session.state }
                guard self.requestID == id else { return }
                if case MobileSQLSessionError.uncertain = error { self.writeOutcomeUncertain = true; self.safetyLock.enable() }
                if !started { self.retrySQL = nil }
                let message = error is CancellationError ? "已取消" : MobileConnectionFeedback.reading(error)
                self.finishBatch(error: error, message: message)
                if error is CancellationError { self.status = "已取消" }
                else { self.errorMessage = message; self.status = "执行停止 · 请核对当前结果" }
            }
        }
        task = request
        return request
    }

    private func authorizeSQL(_ kind: SQLStatementKind, id: UUID, configuration: MariaDBTransportConfiguration) throws {
        guard requestID == id, editorConfiguration == configuration, !isBackgrounded, !Task.isCancelled,
              allowsSQLExecution(), !hasPendingRowChanges else { throw CancellationError() }
        if kind.requiresWriteAccess && safetyLock.isEnabled { throw MobileSQLSessionError.locked }
    }

    private func acceptStream(_ event: MobileSQLSessionEvent, records: [MobileQueryResultState], id: UUID,
                              configuration: MariaDBTransportConfiguration, database: String,
                              start: ContinuousClock.Instant, refresh: Bool) async throws {
        guard requestID == id else { throw CancellationError() }
        switch event {
        case let .started(index):
            try Task.checkCancellation()
            sqlWriteInFlight = records[index].statement.map { $0.kind.requiresWriteAccess || $0.kind == .transaction(.commit) } == true
            activeStatementIndex = index; records[index].phase = .running
            retrySQL = records[index].statement?.kind == .read ? records[index].statement?.sql : nil
            status = "正在执行 \(index + 1)/\(records.count)…"
        case let .progress(index, cache, page, count):
            try Task.checkCancellation()
            let record = records[index]
            // Refresh keeps the existing snapshot until the new query completes.
            if !refresh {
                if statementResults.contains(where: { $0.isPreviousBatch }) { statementResults = records; displayed = records[0] }
                if record.cache == nil || (record.result?.rows.count ?? 0) < page.result.rows.count {
                    record.preview = page; record.result = page.result
                    record.resultRevision = UUID(); record.editing = nil; record.editingPage = nil
                }
                record.cache = cache
                record.cachedRowCount = count; record.cacheComplete = false; record.cacheOffset = 0
            }
            status = "已缓存 \(count) 行…"
        case let .completed(index, cache, page, summary, state, binary):
            let record = records[index]
            if statementResults.contains(where: { $0.isPreviousBatch }) { statementResults = records; displayed = records[0] }
            record.preview = page; record.result = page.result; record.cache = cache
            record.cachedRowCount = summary.rowCount; record.cacheOffset = 0; record.cacheComplete = true; record.previousCacheOffsets = []; record.hasBinaryValues = binary
            record.lastExecutedSQL = record.statement?.sql; record.lastExecutedConfiguration = configuration
            record.lastExecutedDatabase = database; record.lastExecutedRange = record.statement?.range
            record.elapsed = start.duration(to: .now); record.resultRevision = UUID(); record.resultID = UUID()
            record.phase = .completed; record.errorMessage = nil; record.requiresResultReload = false
            record.editing = nil; record.editingPage = nil
            record.status = summary.columns.isEmpty ? "完成 · 影响 \(summary.affectedRows) 行 · 插入 ID \(summary.insertID)" : "完成 · \(summary.rowCount) 行 · \(summary.columns.count) 列（磁盘缓存）"
            transactionState = state; status = record.status
            if let sql = record.lastExecutedSQL { didExecute?(sql, database) }
            if record.statement?.kind == .read, summary.rowCount <= 500, state != .inTransaction, !Task.isCancelled {
                await prepareEditing(preview: page, configuration: configuration, sql: record.lastExecutedSQL ?? "", requestID: id, record: record)
            } else { record.editingMessage = "缓存结果保持只读；请在表数据页修改。事务内请通过 SQL 提交或回滚。" }
            if record.statement?.kind.requiresWriteAccess == true {
                schemaRevision = UUID()
                for other in allResults where other !== record && other.result != nil {
                    other.requiresResultReload = true; other.editing?.requireSuccessfulReload()
                    other.editingMessage = "SQL 已执行写入，使用顶部刷新核对服务器数据后再编辑。"
                }
                didExecuteWrite?()
            }
            if index + 1 == records.count { activeStatementIndex = nil }
        }
    }

    private func acceptBatch(_ event: MobileQueryBatchEvent, records: [MobileQueryResultState], requestID: UUID,
                             configuration: MariaDBTransportConfiguration, database: String, start: ContinuousClock.Instant,
                             refresh: Bool) async throws {
        try Task.checkCancellation()
        guard self.requestID == requestID else { throw CancellationError() }
        switch event {
        case let .started(index):
            guard records.indices.contains(index) else { throw CancellationError() }
            activeStatementIndex = index
            records[index].phase = .running
            retrySQL = records[index].statement?.sql ?? retrySQL
            status = "正在执行 \(index + 1)/\(records.count)…"
        case let .completed(index, preview):
            guard records.indices.contains(index) else { throw CancellationError() }
            let record = records[index]
            if !refresh, statementResults.contains(where: { $0.isPreviousBatch }) {
                statementResults = records; displayed = records[0]
            }
            record.preview = preview; record.result = preview.result
            record.lastExecutedSQL = record.statement?.sql ?? retrySQL
            if !refresh { record.lastExecutedRange = record.statement?.range }
            record.lastExecutedDatabase = database; record.lastExecutedConfiguration = configuration
            record.elapsed = start.duration(to: .now)
            record.resultRevision = UUID(); record.resultID = UUID()
            record.editing = nil; record.editingPage = nil; record.editingMessage = nil
            record.requiresResultReload = false; record.errorMessage = nil; record.phase = .completed
            record.status = preview.result.columns.isEmpty ? "完成 · 影响 \(preview.result.affectedRows) 行" : "完成 · \(preview.result.rows.count) 行 · \(preview.result.columns.count) 列"
            let duration = start.duration(to: .now).components
            record.status += String(format: " · %.2f s", Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            if preview.isTruncated { record.status += " · 已截断（500 行 / 4 MiB 上限）" }
            if let sql = record.lastExecutedSQL { didExecute?(sql, database) }
            // Preserve the single-result lifecycle: rows finish loading before
            // optional editing metadata, which has its own loading state.
            if records.count == 1 { isLoading = false }
            await prepareEditing(preview: preview, configuration: configuration, sql: record.lastExecutedSQL ?? "", requestID: requestID, record: record)
            try Task.checkCancellation()
            guard self.requestID == requestID else { throw CancellationError() }
            if index + 1 == records.count { activeStatementIndex = nil }
        }
    }

    private func finishBatch(error: Error, message: String) {
        let stopped = error is CancellationError
        if let index = activeStatementIndex, activeBatch.indices.contains(index), activeBatch[index].phase == .running {
            let record = activeBatch[index]
            record.phase = stopped ? .stopped : .failed
            record.errorMessage = stopped ? nil : message
            record.status = message
        } else if let record = activeBatch.first, record.phase == .waiting {
            record.phase = stopped ? .stopped : .failed; record.errorMessage = stopped ? nil : message; record.status = message
        }
        for record in activeBatch where record.phase == .waiting {
            record.phase = .skipped; record.status = stopped ? "前序查询已取消，本条未执行" : "前序查询停止，本条未执行"
        }
        activeBatch = []; activeStatementIndex = nil
    }

    private func cancelActiveBatch() { finishBatch(error: CancellationError(), message: "已取消") }

    func cancel() {
        if sqlSession != nil, isLoading {
            safetyLock.enable(); sqlConfirmation = nil; task?.cancel(); status = "正在取消并关闭 SQL 会话…"; return
        }
        cancelActiveBatch()
        requestID = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        isLoadingEditing = false
        status = "已取消"
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        guard backgrounded else { return }
        let wasReading = isLoading, wasLoadingEditing = isLoadingEditing
        if sqlSession != nil { _ = disconnectSQL() }
        safetyLock.enable()
        allResults.forEach { $0.editing?.interruptSubmission() }
        if wasReading || wasLoadingEditing {
            cancel()
            status = "读取已暂停 · 使用顶部刷新重新连接"
            if wasReading { errorMessage = MobileConnectionFeedback.paused }
            if wasLoadingEditing { editingMessage = "编辑元数据读取已暂停。使用顶部刷新重试。" }
        }
    }

    func tableDidChange(_ object: MobileDatabaseObject? = nil) {
        schemaRevision = UUID()
        if isLoading || isLoadingEditing { cancel() }
        for record in allResults {
            if let object, let editing = record.editing, editing.object.editingSelection != object.editingSelection { continue }
            guard record.result != nil else { continue }
            record.requiresResultReload = true
            record.editing?.requireSuccessfulReload()
            record.editingMessage = "表已变更，使用顶部刷新重新读取结果后再编辑。"
        }
    }

    private func configurationChanged() {
        let shouldClose = transactionState != .disconnected || isLoading
        cancel()
        requestID = UUID(); task?.cancel(); task = nil; isLoading = false; isLoadingEditing = false
        if shouldClose, let sqlSession { Task { await sqlSession.disconnect() } }
        transactionState = .disconnected; sqlConfirmation = nil
        statementResults = []; displayed = MobileQueryResultState()
        // Old endpoint results must never appear to belong to the new endpoint.
        result = nil
        preview = nil
        lastExecutedSQL = nil; lastExecutedRange = nil; retrySQL = nil
        lastExecutedDatabase = nil
        lastExecutedConfiguration = nil
        editing = nil; editingPage = nil; editingMessage = nil; resultID = UUID()
        requiresResultReload = false
        elapsed = nil
        resultRevision = UUID()
        errorMessage = nil
        status = "连接已变更 · 执行 SQL 以加载"
    }

    private func prepareEditing(preview: CDatabaseQueryPreview, configuration: MariaDBTransportConfiguration,
                                sql: String, requestID: UUID, record: MobileQueryResultState) async {
        guard let selection = WorkspaceQueryResultEditing.selection(for: preview.result.workspaceColumns, currentDatabase: configuration.database) else {
            record.editingMessage = "只读结果：无法确定唯一基础表。"; return
        }
        isLoadingEditing = true
        defer { if self.requestID == requestID { isLoadingEditing = false } }
        do {
            // Physical protocol origins do not retain relation aliases. A self
            // join can otherwise pair a.id with b.name and update the wrong row.
            let parser = try SQLStructuralParser()
            let syntax = try await parser.parse(.init(revision: .init(1), text: sql))
            try Task.checkCancellation()
            guard self.requestID == requestID else { return }
            guard syntax.isReliable else {
                record.editingMessage = "只读结果：当前语句无法可靠解析，请在表数据页修改。"; return
            }
            guard syntax.relationReferences.count == 1 else {
                record.editingMessage = "只读结果：当前仅支持来源明确的单表查询编辑，关联或嵌套查询请在表数据页修改。"; return
            }
            let catalog = try await metadataService.objects(configuration: configuration, database: selection.databaseName, search: "", kind: .table)
            guard !catalog.hasMore, let object = catalog.objects.first(where: { $0.kind == .table && $0.name == selection.objectName }) else {
                throw WorkspaceDatabaseDataCellEditError.tableRequired
            }
            try Task.checkCancellation()
            guard self.requestID == requestID else { return }
            let columns = try await metadataService.columns(configuration: configuration, object: object)
            try Task.checkCancellation()
            guard self.requestID == requestID else { return }
            let identity = record.resultID
            let changes = MobileTableChanges(object: object, metadata: columns, configuration: configuration,
                safetyLock: safetyLock, service: mutationService, isQueryResult: true)
            changes.isContextCurrent = { [weak self] in
                self?.resultID == identity && self?.lastExecutedConfiguration == configuration && self?.isLoading == false
                    && self?.requiresResultReload == false && self?.isBackgrounded == false && self?.allowsDataMutation() == true
                    && self?.blocksOtherWrites == false
            }
            changes.didApply = { [weak self] committed in self?.applyCommitted(committed, resultID: identity) }
            changes.didDiscardUncertain = { [weak self, weak record] in
                guard let self, let record, self.resultID == identity else { return }
                record.requiresResultReload = true
                record.editingMessage = "提交结果待核实，请重新执行查询后再编辑。"
            }
            record.editingPage = .init(object: object, preview: preview, columns: columns, offset: 0,
                pageSize: max(1, preview.result.rows.count), hasNextPage: preview.isTruncated, hasStableOrder: false)
            record.editing = changes
            record.editingMessage = nil
        } catch {
            guard self.requestID == requestID, !(error is CancellationError) else { return }
            record.editingMessage = "结果保持只读：\(MobileConnectionFeedback.reading(error)) 使用顶部刷新重试。"
        }
    }

    private func applyCommitted(_ changes: WorkspaceDatabaseDataChangeSet, resultID: UUID) {
        guard self.resultID == resultID, let preview, let page = editingPage else { return }
        displayed.cache = nil; displayed.cachedRowCount = 0
        let patched = MobileQueryResultPatch.apply(changes, to: preview)
        self.preview = patched; result = patched.result; errorMessage = nil
        editingPage = .init(object: page.object, preview: patched, columns: page.columns, offset: 0,
            pageSize: page.pageSize, hasNextPage: page.hasNextPage, hasStableOrder: false)
        resultRevision = UUID()
        status = "已保存 · \(patched.result.rows.count) 行 · 计算列与默认值可重新执行查询更新"
        displayed.status = status; displayed.errorMessage = nil; displayed.phase = .completed
        for record in allResults where record !== displayed {
            let sameTable = record.result?.workspaceColumns.contains { column in
                column.origin?.tableName == page.object.name && column.origin?.databaseName == page.object.database
            } == true
            if sameTable {
                record.requiresResultReload = true; record.editing?.requireSuccessfulReload()
                record.editingMessage = "同一表的其他结果已提交修改，请核对草稿并刷新本结果后再编辑。"
            }
        }
        if changes.updates.contains(where: { $0.assignment == .useDefault }) {
            requiresResultReload = true
            editingMessage = "默认值已提交，请重新执行查询读取服务器实际值后再编辑。"
        }
    }
}
