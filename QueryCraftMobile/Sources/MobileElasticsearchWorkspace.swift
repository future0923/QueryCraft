import Foundation
import Observation
import QueryCraftMobileCore

protocol MobileElasticsearchServing: WorkspaceRequestExecutingSession, WorkspaceDocumentInspectorSession, WorkspaceDocumentEditingSession, WorkspaceMappingEditingSession { func refreshReadState() async }
extension ElasticsearchWorkspaceSession: MobileElasticsearchServing {}

private actor MobileElasticsearchBatch {
    var value: WorkspaceDatabaseDataBatch?
    func receive(_ batch: WorkspaceDatabaseDataBatch) { value = batch }
    func result() -> WorkspaceDatabaseDataBatch? { value }
}

@MainActor @Observable final class MobileElasticsearchWorkspace {
    let profile: MobileConnectionProfile
    let cellChanges = WorkspaceElasticsearchCellChangesModel()
    let safetyLock = WorkspaceSafetyLock()
    private(set) var session: (any MobileElasticsearchServing)?
    @ObservationIgnored private let makeSession: @Sendable () throws -> any MobileElasticsearchServing
    private(set) var catalog: [WorkspaceDatabaseObject]?
    private(set) var selected: WorkspaceDatabaseObject?
    private(set) var page: WorkspaceDatabaseDataPage?
    private(set) var mapping: WorkspaceMappingSnapshot?
    private(set) var isLoadingCatalog = false
    private(set) var isLoadingPage = false
    private(set) var catalogError: String?
    private(set) var pageError: String?
    private(set) var isBackgrounded = false
    var search = ""
    var showsMapping = false
    var showsConsole = false
    var showsFilter = false
    var fullscreenAction: MobileElasticsearchAction?
    var action: MobileElasticsearchAction?
    var console: MobileElasticsearchConsole!
    private(set) var sort = WorkspaceDatabaseDataSort.none
    private(set) var filter = WorkspaceDatabaseDataFilter.empty
    private(set) var pageSize: Int
    private(set) var totalCount: Int?
    private(set) var requiresRefresh = false
    private(set) var revision = UUID()
    let viewport = MobileGridViewport()
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var catalogID = UUID()
    @ObservationIgnored private var pageID = UUID()
    @ObservationIgnored private var closing: Task<Void, Never>?
    var hasPendingChanges: Bool { cellChanges.hasChanges || action != nil || fullscreenAction != nil || console.hasPendingChanges }
    var isLoading: Bool { isLoadingCatalog || isLoadingPage || console.isRunning || action?.isBusy == true }
    var visibleObjects: [WorkspaceDatabaseObject] { CompletionLabelMatcher.matching(catalog ?? [], query: search, label: \.name) }
    var canNavigate: Bool { !hasPendingChanges && !isBackgrounded }
    var originalData: MobileGridData {
        guard let page else { return .init(columns: [], rows: []) }
        return .init(esColumns: page.columns, rows: page.rows)
    }
    var data: MobileGridData {
        guard let page else { return .init(columns: [], rows: []) }
        let rows = page.rows.map { row -> WorkspaceDatabaseDataRow in
            guard let reference = documentReference(row: row, columns: page.columns), let entry = cellChanges.entries[reference] else { return row }
            let values = page.columns.enumerated().map { index, column in entry.edits[column.name] ?? row.values[index] }
            return .init(id: row.id, values: values)
        }
        var data = MobileGridData(esColumns: page.columns, rows: rows)
        for (index, row) in page.rows.enumerated() {
            guard let reference = documentReference(row: row, columns: page.columns), let entry = cellChanges.entries[reference] else { continue }
            for column in page.columns where entry.edits[column.name] != nil { data.pendingCells.insert(.init(row: index, column: column.id)) }
        }
        return data
    }
    var mappingData: MobileGridData {
        .init(columns: ["字段", "类型", "可搜索", "可聚合", "类型冲突"], rows: (mapping?.fieldCapabilities ?? []).map {
            [$0.path, $0.type, $0.isSearchable ? "是" : "否", $0.isAggregatable ? "是" : "否", $0.hasTypeConflict ? "是" : "否"]
        })
    }
    var status: String {
        if requiresRefresh { return "服务器内容已更改，请使用顶部刷新读取。" }
        guard let page else { return "等待加载" }
        return "第 \(page.offset + (page.rowCount == 0 ? 0 : 1))–\(page.offset + page.rowCount) 条" + (totalCount.map { " · 共 \($0) 条" } ?? "")
    }
    init(profile: MobileConnectionProfile, password: String?, session: (any MobileElasticsearchServing)? = nil, sessionFactory: (@Sendable () throws -> any MobileElasticsearchServing)? = nil, preferences: MobilePreferences = .shared) {
        pageSize = preferences.tableDataPageSize
        self.profile = profile
        let authentication: DatabaseConnectionAuthentication = switch profile.authentication {
        case .usernamePassword: .usernamePassword(username: profile.username, password: password)
        case .apiKey: .apiKey(password ?? "")
        case .none: .none
        }
        let configuration = ElasticsearchConnectionConfiguration(host: profile.host, port: profile.port, authentication: authentication, tlsMode: profile.tlsMode)
        let factory: @Sendable () throws -> any MobileElasticsearchServing = sessionFactory ?? {
            if session != nil { throw MobileElasticsearchFailure.unavailable }
            return try ElasticsearchWorkspaceSession(configuration: configuration, maximumResponseBytes: 16_777_216)
        }
        self.makeSession = factory
        self.session = session ?? (try? factory())
        console = MobileElasticsearchConsole(owner: self)
    }
    func ready() async throws -> any MobileElasticsearchServing {
        try Task.checkCancellation()
        if let closing { await closing.value }
        try Task.checkCancellation()
        guard !isBackgrounded else { throw CancellationError() }
        if session == nil { session = try makeSession() }
        guard let session else { throw MobileQueryError.invalidConnection }
        try await session.connect()
        try Task.checkCancellation()
        return session
    }
    @discardableResult func loadCatalog() -> Task<Void, Never>? {
        guard canNavigate else { return nil }
        let previous = catalogTask
        catalogTask?.cancel(); catalogID = UUID(); let id = catalogID
        isLoadingCatalog = true; catalogError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                await previous?.value; try Task.checkCancellation()
                let service = try await ready()
                let objects = try await service.fetchObjects(in: "Elasticsearch")
                try Task.checkCancellation()
                guard id == catalogID else { return }
                guard objects.count <= 10_000, objects.reduce(0, { $0 + $1.name.utf8.count }) <= 8_388_608 else { throw MobileQueryError.resultTooLarge }
                catalog = objects
                if let selected, !objects.contains(where: { $0.id == selected.id }) { self.selected = nil; page = nil; mapping = nil }
            } catch {
                guard id == catalogID else { return }
                if !(error is CancellationError) { catalogError = error.localizedDescription }
            }
            guard id == catalogID else { return }
            isLoadingCatalog = false; catalogTask = nil
        }
        catalogTask = task; return task
    }
    func select(_ object: WorkspaceDatabaseObject?) {
        guard canNavigate, object?.id != selected?.id else { return }
        cancelPage(); selected = object; page = nil; mapping = nil; totalCount = nil
        sort = .none; filter = .empty; requiresRefresh = false; revision = UUID()
        if object != nil { loadPage(offset: 0, fresh: true) }
    }
    @discardableResult func loadPage(offset: Int? = nil, fresh: Bool = false) -> Task<Void, Never>? {
        guard canNavigate, let object = selected else { return nil }
        let previous = pageTask
        cancelPage(); let id = pageID
        let requestedOffset = offset ?? page?.offset ?? 0, size = pageSize, sort = sort, filter = filter
        isLoadingPage = true; pageError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                await previous?.value; try Task.checkCancellation()
                let service = try await ready()
                if fresh { await service.refreshReadState(); try Task.checkCancellation() }
                let count = fresh || totalCount == nil ? try await service.fetchDataCount(for: object, in: "Elasticsearch", filter: filter) : totalCount
                let target = fresh ? WorkspaceElasticsearchPageRefresh.offset(requested: requestedOffset, limit: size, totalCount: count) : requestedOffset
                let snapshot = try await service.fetchMappingSnapshot(.init(resource: object.name, kind: object.kind))
                let sink = MobileElasticsearchBatch()
                let result = try await service.fetchDataPage(for: object, in: "Elasticsearch", offset: target, limit: size, sort: sort, filter: filter) { await sink.receive($0) }
                let batch = await sink.result()
                try Task.checkCancellation()
                guard pageID == id, selected?.id == object.id else { return }
                page = .init(columns: result.columns, rows: batch?.rows ?? [], offset: target, limit: size, hasNextPage: result.hasNextPage, sort: sort, filter: filter)
                mapping = snapshot; totalCount = count; requiresRefresh = false; revision = UUID()
            } catch {
                guard pageID == id else { return }
                if !(error is CancellationError) { pageError = error.localizedDescription }
            }
            guard pageID == id else { return }
            isLoadingPage = false; pageTask = nil
        }
        pageTask = task; return task
    }
    func apply(filter: WorkspaceDatabaseDataFilter) { guard canNavigate else { return }; self.filter = filter; loadPage(offset: 0, fresh: true) }
    func setSort(_ sort: WorkspaceDatabaseDataSort) { guard canNavigate else { return }; self.sort = sort; loadPage(offset: 0, fresh: true) }
    func setPageSize(_ size: Int) { guard canNavigate, MobilePreferences.pageSizes.contains(size) else { return }; pageSize = size; loadPage(offset: 0, fresh: true) }
    func next() { guard let page, page.hasNextPage, !isLoadingPage else { return }; loadPage(offset: page.offset + page.limit) }
    func previous() { guard let page, page.offset > 0, !isLoadingPage else { return }; loadPage(offset: max(0, page.offset - page.limit)) }
    func refresh() {
        if let action { action.reload(); return }
        if showsConsole { console.refresh(); return }
        if selected != nil { loadPage(fresh: true) } else { loadCatalog() }
    }
    func didWrite() { requiresRefresh = true; revision = UUID() }
    var exportSessionFactory: @Sendable () throws -> any MobileElasticsearchServing { makeSession }
    func didStage() { revision = UUID() }
    func cancelPage() { pageID = UUID(); pageTask?.cancel(); pageTask = nil; isLoadingPage = false }
    func cancel() {
        let pendingCatalog = catalogTask, pendingPage = pageTask
        catalogID = UUID(); catalogTask?.cancel(); catalogTask = nil; isLoadingCatalog = false; cancelPage()
        safetyLock.enable(); console.cancel(); action?.cancelRead(); fullscreenAction?.cancelRead()
        if action?.isSubmitting != true, fullscreenAction?.isSubmitting != true, !console.isWriting, let session {
            self.session = nil
            let previous = closing, action = action, fullscreenAction = fullscreenAction, console = console
            closing = Task {
                await previous?.value; await pendingCatalog?.value; await pendingPage?.value
                await action?.waitForReadCancellation(); await fullscreenAction?.waitForReadCancellation(); await console?.waitForReadCancellation()
                await session.close()
            }
        }
    }
    func setBackgrounded(_ value: Bool) {
        isBackgrounded = value; action?.setBackgrounded(value); fullscreenAction?.setBackgrounded(value); console.setBackgrounded(value)
        if value { cancel() }
    }
    func begin(_ kind: MobileElasticsearchAction.Kind, row: Int? = nil) {
        guard canNavigate || !isBackgrounded && action == nil && !console.hasPendingChanges && (kind == .document || kind == .cellChanges) else { return }
        var reference: WorkspaceDocumentReference?
        if let row, let page, let item = page.row(at: row) {
            func field(_ name: String) -> String? { guard let index = page.columns.firstIndex(where: { $0.name == name }), case .text(let value) = item.values[index] else { return nil }; return value }
            if let index = field("_index"), let id = field("_id") { reference = .init(index: index, id: id, routing: field("_routing")) }
        }
        action = .init(owner: self, kind: kind, object: selected, reference: reference)
        let current = action, loading = pageTask
        Task { await loading?.value; guard action === current else { return }; current?.reload() }
    }
    func documentReference(row: WorkspaceDatabaseDataRow, columns: [WorkspaceDatabaseDataColumn]) -> WorkspaceDocumentReference? {
        func value(_ name: String) -> String? {
            guard let index = columns.firstIndex(where: { $0.name == name }), row.values.indices.contains(index), case .text(let text) = row.values[index] else { return nil }; return text
        }
        guard let index = value("_index"), let id = value("_id") else { return nil }
        return .init(index: index, id: id, routing: value("_routing"))
    }

    func beginFullscreenDocument(row: Int) {
        guard action == nil, fullscreenAction == nil, !isBackgrounded, !isLoadingPage, let page, let row = page.row(at: row), let reference = documentReference(row: row, columns: page.columns) else { return }
        let action = MobileElasticsearchAction(owner: self, kind: .document, object: selected, reference: reference)
        fullscreenAction = action; action.reload()
    }

    func beginFullscreenChanges() {
        guard action == nil, fullscreenAction == nil, !isBackgrounded, !isLoadingPage, cellChanges.hasChanges else { return }
        let action = MobileElasticsearchAction(owner: self, kind: .cellChanges, object: selected, reference: nil)
        fullscreenAction = action; action.reload()
    }

}
