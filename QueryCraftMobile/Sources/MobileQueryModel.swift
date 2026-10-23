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
    private(set) var lastExecutedRange: SQLSourceRange?
    private(set) var result: CDatabaseQueryResult?
    private(set) var preview: CDatabaseQueryPreview?
    private(set) var lastExecutedSQL: String?
    private(set) var lastExecutedDatabase: String?
    private(set) var elapsed: Duration?
    private(set) var isLoading = false
    private var queryErrorMessage: String?
    private var blockedByPendingChanges = false
    private(set) var errorMessage: String? {
        get { blockedByPendingChanges && hasPendingChanges ? MobileDataMutationError.pendingChanges.localizedDescription : queryErrorMessage }
        set { queryErrorMessage = newValue; blockedByPendingChanges = false }
    }
    private(set) var status = "填写连接后执行 SQL"
    private(set) var resultRevision = UUID()
    private(set) var resultID = UUID()
    private(set) var schemaRevision = UUID()
    private(set) var editing: MobileTableChanges?
    private(set) var editingPage: MobileTableSnapshot?
    private(set) var editingMessage: String?
    private(set) var isLoadingEditing = false
    private(set) var lastExecutedConfiguration: MariaDBTransportConfiguration?
    private(set) var requiresResultReload = false
    private(set) var isBackgrounded = false
    @ObservationIgnored var allowsDataMutation: () -> Bool = { true }
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
        self.metadataService = metadataService; self.mutationService = mutationService; self.safetyLock = safetyLock
    }

    var hasPendingChanges: Bool { editing.map { $0.hasChanges || $0.isSubmitting } ?? false }
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

    @discardableResult
    func execute() -> Task<Void, Never>? { startExecution(capturedSQL: nil) }

    /// Refresh the actual result/failed attempt, independent of later caret or
    /// draft changes. The same pending/context/cancellation guards still apply.
    @discardableResult func refresh() -> Task<Void, Never>? { startExecution(capturedSQL: retrySQL) }

    private func startExecution(capturedSQL: String?) -> Task<Void, Never>? {
        guard !isBackgrounded else { return nil }
        guard !protectPendingChanges(), (capturedSQL != nil || canExecute), let configuration = editorConfiguration else { return nil }
        let source = SQLSourceSnapshot(revision: .init(sourceRevision), text: self.sql)
        let selection: NSRange
        do {
            guard capturedSQL != nil || source.text.utf8.count <= 262_144 else { throw MobileSQLExecutionError.documentTooLarge }
            selection = capturedSQL == nil ? try executionInput.capture(text: source.text) : .init(location: 0, length: 0)
        } catch {
            retrySQL = nil; errorMessage = error.localizedDescription; status = "执行范围不可用"; return nil
        }
        task?.cancel()
        let id = UUID()
        requestID = id
        let database = self.database
        let start = ContinuousClock.now
        isLoading = true
        isLoadingEditing = false
        errorMessage = nil
        status = capturedSQL == nil ? "正在确定执行语句…" : "正在刷新查询结果…"
        let executor = self.executor, planner = executionPlanner
        let request = Task { [weak self] in
            var started = false
            do {
                let sql: String, range: SQLSourceRange?
                if let capturedSQL { sql = capturedSQL; range = nil }
                else {
                    let plan = try await planner.plan(source: source, selection: selection)
                    try Task.checkCancellation()
                    guard let self, self.requestID == id else { return }
                    guard self.sourceRevision == source.revision.rawValue, self.sql == source.text,
                          self.executionInput.matches(text: source.text, selection: selection) else {
                        throw SQLExecutionTargetError.sourceChanged
                    }
                    guard plan.statements.count == 1 else { throw MobileSQLExecutionError.multipleStatements }
                    guard let statement = plan.statements.first, statement.kind == .read else { throw MobileQueryError.readOnlySQLRequired }
                    sql = statement.sql; range = statement.range
                }
                // Structural target selection is shared with Mac. The existing
                // MySQL mode-aware transport policy still validates before SQL.
                guard let self, self.requestID == id else { return }
                self.retrySQL = sql; started = true
                self.status = "正在连接并执行…"
                let preview = try await executor.preview(configuration: configuration, sql: sql, maximumRows: 500, maximumBytes: 4_194_304)
                let result = preview.result
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                self.preview = preview
                self.result = result
                self.lastExecutedSQL = sql
                self.lastExecutedRange = range
                self.lastExecutedDatabase = database
                self.elapsed = start.duration(to: .now)
                self.resultRevision = UUID()
                self.resultID = UUID()
                self.lastExecutedConfiguration = configuration
                self.editing = nil; self.editingPage = nil; self.editingMessage = nil
                self.requiresResultReload = false
                self.status = result.columns.isEmpty
                    ? "完成 · 影响 \(result.affectedRows) 行"
                    : "完成 · \(result.rows.count) 行 · \(result.columns.count) 列"
                let duration = start.duration(to: .now).components
                self.status += String(format: " · %.2f s", Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                if preview.isTruncated { self.status += " · 已截断（500 行 / 4 MiB 上限）" }
                self.isLoading = false
                await self.prepareEditing(preview: preview, configuration: configuration, sql: sql, requestID: id)
                guard self.requestID == id else { return }
                self.task = nil
            } catch {
                guard let self, self.requestID == id else { return }
                self.isLoading = false
                self.task = nil
                if !started { self.retrySQL = nil }
                if error is CancellationError {
                    self.status = "已取消"
                } else {
                    self.errorMessage = MobileConnectionFeedback.reading(error)
                    self.status = "执行失败 · 可使用顶部刷新重试"
                }
            }
        }
        task = request
        return request
    }

    func cancel() {
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
        safetyLock.enable()
        editing?.interruptSubmission()
        let wasReading = isLoading, wasLoadingEditing = isLoadingEditing
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
        if let object, let editing, editing.object.editingSelection != object.editingSelection { return }
        guard result != nil else { return }
        requiresResultReload = true
        editing?.requireSuccessfulReload()
        editingMessage = "表已变更，使用顶部刷新重新读取结果后再编辑。"
    }

    private func configurationChanged() {
        cancel()
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
                                sql: String, requestID: UUID) async {
        guard let selection = WorkspaceQueryResultEditing.selection(for: preview.result.workspaceColumns, currentDatabase: configuration.database) else {
            editingMessage = "只读结果：无法确定唯一基础表。"; return
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
                editingMessage = "只读结果：当前语句无法可靠解析，请在表数据页修改。"; return
            }
            guard syntax.relationReferences.count == 1 else {
                editingMessage = "只读结果：当前仅支持来源明确的单表查询编辑，关联或嵌套查询请在表数据页修改。"; return
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
            let identity = resultID
            let changes = MobileTableChanges(object: object, metadata: columns, configuration: configuration,
                safetyLock: safetyLock, service: mutationService, isQueryResult: true)
            changes.isContextCurrent = { [weak self] in
                self?.resultID == identity && self?.lastExecutedConfiguration == configuration && self?.isLoading == false
                    && self?.requiresResultReload == false && self?.isBackgrounded == false && self?.allowsDataMutation() == true
            }
            changes.didApply = { [weak self] committed in self?.applyCommitted(committed, resultID: identity) }
            changes.didDiscardUncertain = { [weak self] in
                guard let self, self.resultID == identity else { return }
                self.requiresResultReload = true
                self.editingMessage = "提交结果待核实，请重新执行查询后再编辑。"
            }
            editingPage = .init(object: object, preview: preview, columns: columns, offset: 0,
                pageSize: max(1, preview.result.rows.count), hasNextPage: preview.isTruncated, hasStableOrder: false)
            editing = changes
            editingMessage = nil
        } catch {
            guard self.requestID == requestID, !(error is CancellationError) else { return }
            editingMessage = "结果保持只读：\(MobileConnectionFeedback.reading(error)) 使用顶部刷新重试。"
        }
    }

    private func applyCommitted(_ changes: WorkspaceDatabaseDataChangeSet, resultID: UUID) {
        guard self.resultID == resultID, let preview, let page = editingPage else { return }
        let patched = MobileQueryResultPatch.apply(changes, to: preview)
        self.preview = patched; result = patched.result; errorMessage = nil
        editingPage = .init(object: page.object, preview: patched, columns: page.columns, offset: 0,
            pageSize: page.pageSize, hasNextPage: page.hasNextPage, hasStableOrder: false)
        resultRevision = UUID()
        status = "已保存 · \(patched.result.rows.count) 行 · 计算列与默认值可重新执行查询更新"
        if changes.updates.contains(where: { $0.assignment == .useDefault }) {
            requiresResultReload = true
            editingMessage = "默认值已提交，请重新执行查询读取服务器实际值后再编辑。"
        }
    }
}
