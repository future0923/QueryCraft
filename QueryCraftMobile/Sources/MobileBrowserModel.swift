import Foundation
import Observation
import QueryCraftMobileTransport
import QueryCraftMobileCore

@MainActor @Observable
final class MobileBrowserModel {
    enum Tab: String, CaseIterable { case data = "数据", structure = "结构" }
    private(set) var revision = UUID()
    private(set) var contextID = UUID()
    @ObservationIgnored var allowsDataMutation: () -> Bool = { true }
    @ObservationIgnored var allowsDatabaseChange: () -> Bool = { true }
    private(set) var databases: [String]?
    private(set) var selectedDatabase: String?
    private(set) var schemas: [String]?
    private(set) var selectedSchema: String?
    @ObservationIgnored private var schemaWasExplicitlySelected = false
    var supportsReadOnlyStructure: Bool { configuration.driver == .doris }
    var supportsSchemas: Bool { configuration.driver == .postgresql }
    private(set) var catalog: MobileObjectCatalog?
    private(set) var catalogKind: MobileDatabaseObject.Kind = .table
    private(set) var selectedObject: MobileDatabaseObject?
    private(set) var snapshot: MobileTableSnapshot?
    private(set) var columns: [MobileTableColumn]?
    private(set) var readOnlyStructure: MobileReadOnlyStructure?
    private(set) var isLoadingCatalog = false
    private(set) var isLoadingTable = false
    private(set) var catalogError: String?
    private(set) var tableError: String?
    let supportsEditing: Bool
    var supportsSchemaEditing: Bool { supportsEditing && (configuration.driver == .mysql || configuration.driver == .postgresql) }
    let safetyLock = WorkspaceSafetyLock()
    private(set) var changesByObject: [String: MobileTableChanges] = [:]
    var schema: MobileSchemaController?
    var hasPendingChanges: Bool { (schema?.hasPendingChanges ?? false) || changesByObject.values.contains { $0.hasChanges || $0.isSubmitting } }
    var currentChanges: MobileTableChanges? { selectedObject.flatMap { changesByObject[$0.id] } }
    private let mutationService: any MobileDataMutating
    var search = ""
    var objectsInSelectedSchema: [MobileDatabaseObject] {
        (catalog?.objects ?? []).filter { selectedSchema == nil || $0.schemaName == selectedSchema }
    }
    var visibleObjects: [MobileDatabaseObject] {
        MobileCatalogSearch.objects(objectsInSelectedSchema, matching: search)
    }
    @ObservationIgnored var didRestoreSelection: ((MobileDatabaseObject) -> Void)?
    @ObservationIgnored private var pendingRestoration: MobileBrowserRestoration?
    var tab: Tab = .data
    var pageSize: Int
    private(set) var sortColumn: String?
    private(set) var ascending = true
    private(set) var dataFilter = WorkspaceDatabaseDataFilter.empty
    @ObservationIgnored private let configuration: MobileSQLConfiguration
    @ObservationIgnored private let service: any MobileSQLServicing
    @ObservationIgnored private var catalogID = UUID()
    @ObservationIgnored private var tableID = UUID()
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var tableTask: Task<Void, Never>?
    private(set) var isBackgrounded = false

    init(configuration: MobileSQLConfiguration, service: any MobileSQLServicing = MobileMySQLService(), mutationService: any MobileDataMutating = MobileDataMutationService(), supportsEditing: Bool = true, preferences: MobilePreferences = .shared) {
        pageSize = preferences.tableDataPageSize
        self.supportsEditing = supportsEditing
        self.configuration = configuration
        self.selectedSchema = configuration.schemaName
        self.service = service
        self.mutationService = mutationService
    }

    /// Capture committed state, never the requested filter/sort of an in-flight refresh.
    func dataExportSnapshot() -> MobileDataExportSnapshot? {
        guard !isLoadingTable, let snapshot, snapshot.object == selectedObject else { return nil }
        var export = MobileDataExportSnapshot.table(snapshot, configuration: configuration, service: service)
        export.sqlDialect = configuration.driver == .postgresql ? .postgresql : configuration.driver == .doris ? .doris : .mysql
        return export
    }

    @discardableResult
    func loadDatabases() -> Task<Void, Never> {
        guard !isBackgrounded else { return Task {} }
        catalogTask?.cancel()
        let id = UUID(); catalogID = id
        isLoadingCatalog = true; catalogError = nil
        let task = Task { [weak self, service, configuration] in
            do {
                let databases = try await service.databases(configuration: configuration)
                try Task.checkCancellation()
                guard let self, self.catalogID == id else { return }
                self.databases = databases
                self.isLoadingCatalog = false
                self.catalogTask = nil
                let preferred = (configuration.database ?? (configuration.driver == .postgresql ? "postgres" : nil)).flatMap { databases.contains($0) ? $0 : nil }
                if self.selectedDatabase == nil { self.selectDatabase(preferred ?? databases.first) }
                else if let selected = self.selectedDatabase, !databases.contains(selected) { self.selectDatabase(nil) }
                else if self.catalog == nil { self.loadObjects() }
            } catch {
                guard let self, self.catalogID == id else { return }
                self.isLoadingCatalog = false; self.catalogTask = nil
                if !(error is CancellationError) { self.catalogError = MobileConnectionFeedback.reading(error) }
            }
        }
        catalogTask = task
        return task
    }

    func restore(_ state: MobileBrowserRestoration) {
        guard databases == nil else { return }
        restoreDatabaseContext(database: state.database ?? "", schema: state.schema)
        catalogKind = state.kind; pendingRestoration = state
        schemaWasExplicitlySelected = state.schemaWasExplicitlySelected ?? (state.schema != nil)
    }
    var restoration: MobileBrowserRestoration {
        .init(database: selectedDatabase, schema: selectedSchema, kind: catalogKind, object: selectedObject,
            section: tab.rawValue, search: search, pageSize: pageSize, offset: snapshot?.offset ?? 0,
            sortColumn: sortColumn, ascending: ascending, filter: dataFilter, schemaWasExplicitlySelected: schemaWasExplicitlySelected)
    }

    func restoreDatabaseContext(database: String, schema: String?) {
        guard databases == nil else { return }
        selectedDatabase = database.isEmpty ? nil : database
        selectedSchema = schema; schemaWasExplicitlySelected = true
    }

    func selectDatabase(_ name: String?) {
        guard name != selectedDatabase || catalog == nil else { return }
        guard allowsDatabaseChange() else {
            catalogError = "请先提交或回滚 SQL 事务，并处理待核实的写入结果后再切换数据库。"; return
        }
        cancelAll()
        revision = UUID()
        contextID = UUID()
        selectedDatabase = name; schemaWasExplicitlySelected = false; schemas = nil; selectedSchema = configuration.schemaName; catalog = nil; search = ""; catalogError = nil
        selectedObject = nil; snapshot = nil; columns = nil; readOnlyStructure = nil; tableError = nil
        sortColumn = nil; dataFilter = .empty
        if name != nil { loadObjects() }
    }

    func selectSchema(_ name: String?) {
        guard allowsDatabaseChange() else { return }
        schemaWasExplicitlySelected = true
        guard name != selectedSchema else { return }
        cancelAll(); selectedSchema = name; selectedObject = nil; snapshot = nil; columns = nil; readOnlyStructure = nil
        sortColumn = nil; dataFilter = .empty; tableError = nil; search = ""
        revision = UUID(); contextID = UUID()
        if catalog == nil { loadObjects() }
    }

    func selectKind(_ kind: MobileDatabaseObject.Kind) {
        guard catalogKind != kind else { return }
        cancelAll()
        contextID = UUID()
        catalogKind = kind; catalog = nil; search = ""; catalogError = nil
        selectedObject = nil; snapshot = nil; columns = nil; readOnlyStructure = nil; tableError = nil; sortColumn = nil
        revision = UUID()
        dataFilter = .empty
        loadObjects()
    }

    @discardableResult
    func loadObjects() -> Task<Void, Never>? {
        guard !isBackgrounded else { return nil }
        guard let database = selectedDatabase else { return nil }
        catalogTask?.cancel()
        let id = UUID(); catalogID = id
        let kind = catalogKind
        isLoadingCatalog = true; catalogError = nil
        let task = Task { [weak self, service, configuration] in
            do {
                try Task.checkCancellation()
                let schemas = configuration.driver == .postgresql ? try await service.schemas(configuration: configuration, database: database) : []
                let catalog = try await service.objects(configuration: configuration, database: database, search: "", kind: kind)
                try Task.checkCancellation()
                guard let self, self.catalogID == id, self.selectedDatabase == database, self.catalogKind == kind else { return }
                let firstSchemaLoad = self.schemas == nil
                self.schemas = schemas
                if self.supportsSchemas, (firstSchemaLoad && !self.schemaWasExplicitlySelected) || self.selectedSchema.map({ !schemas.contains($0) }) == true {
                    self.selectedSchema = self.selectedSchema.flatMap { schemas.contains($0) ? $0 : nil }
                        ?? (schemas.contains("public") ? "public" : schemas.first)
                }
                self.catalog = catalog
                if let state = self.pendingRestoration {
                    self.pendingRestoration = nil
                    self.search = state.search
                    if let saved = state.object, let object = catalog.objects.first(where: { $0.id == saved.id }) {
                        self.selectedObject = object
                        self.tab = Tab(rawValue: state.section) ?? .data
                        self.pageSize = min(500, max(1, state.pageSize))
                        self.sortColumn = state.sortColumn; self.ascending = state.ascending; self.dataFilter = state.filter
                        self.didRestoreSelection?(object)
                        self.loadTable(offset: min(max(0, state.offset), Int.max - 500))
                    }
                }
                self.isLoadingCatalog = false; self.catalogTask = nil
                // Search filters only presentation; refresh always checks the complete catalog.
                if !catalog.hasMore, let object = self.selectedObject,
                   !catalog.objects.contains(where: { $0.id == object.id }) {
                    self.cancelTable()
                    self.revision = UUID()
                    self.selectedObject = nil; self.snapshot = nil; self.columns = nil; self.readOnlyStructure = nil
                }
            } catch {
                guard let self, self.catalogID == id else { return }
                self.isLoadingCatalog = false; self.catalogTask = nil
                if !(error is CancellationError) { self.catalogError = MobileConnectionFeedback.reading(error) }
            }
        }
        catalogTask = task
        return task
    }

    @discardableResult
    func selectObject(_ object: MobileDatabaseObject) -> Task<Void, Never>? {
        guard object.database == selectedDatabase, object.kind == catalogKind else { return nil }
        _ = schema?.draft(for: object)
        if selectedObject?.id != object.id {
            cancelTable()
            revision = UUID()
            selectedObject = object; snapshot = nil; columns = nil; readOnlyStructure = nil
            tableError = nil; sortColumn = nil; ascending = true; tab = .data
            dataFilter = .empty
        } else if snapshot != nil && columns != nil { return nil }
        return loadTable(offset: 0)
    }

    @discardableResult
    func loadTable(offset: Int? = nil, reloadColumns: Bool = false) -> Task<Void, Never>? {
        guard !isBackgrounded else { return nil }
        guard let object = selectedObject else { return nil }
        if tab == .structure, let schema {
            cancelTable()
            return schema.load(object)
        }
        schema?.cancelRead()
        tableTask?.cancel()
        let id = UUID(); tableID = id
        let filter = dataFilter
        let offset = offset ?? (snapshot?.filter == filter ? snapshot?.offset ?? 0 : 0)
        let cachedColumns = reloadColumns ? nil : columns
        let size = pageSize, sort = sortColumn, ascending = self.ascending, tab = self.tab
        isLoadingTable = true; tableError = nil
        let task = Task { [weak self, service, configuration] in
            var fetchedColumns: [MobileTableColumn]?
            do {
                let columns: [MobileTableColumn]
                if let cachedColumns { columns = cachedColumns }
                else { columns = try await service.columns(configuration: configuration, object: object) }
                fetchedColumns = columns
                try Task.checkCancellation()
                let structure: MobileReadOnlyStructure?
                if tab == .structure, let doris = service as? MobileDorisService {
                    structure = try await doris.structure(configuration: configuration, object: object)
                } else { structure = nil }
                let page: MobileTableSnapshot?
                if tab == .data {
                    page = try await service.page(configuration: configuration, object: object, columns: columns,
                        offset: offset, size: size, sortColumn: sort, ascending: ascending, filter: filter)
                } else { page = nil }
                try Task.checkCancellation()
                guard let self, self.tableID == id, self.selectedObject?.id == object.id else { return }
                self.columns = columns
                if tab == .structure { self.readOnlyStructure = structure }
                self.revision = UUID()
                if var page {
                    page.filter = filter; page.sortColumn = sort; page.ascending = ascending; self.snapshot = page
                    if let changes = self.changesByObject[object.id] { changes.receive(metadata: columns) }
                    else if object.kind == .table && self.supportsEditing {
                        let changes = MobileTableChanges(object: object, metadata: columns, configuration: configuration,
                            safetyLock: self.safetyLock, service: self.mutationService)
                        changes.isContextCurrent = { [weak self] in
                            self?.selectedObject == object && self?.isLoadingTable == false && self?.isBackgrounded == false && self?.allowsDataMutation() == true
                        }
                        changes.didCommit = { [weak self] in
                            guard let self else { return }
                            if self.isBackgrounded { self.changesByObject[object.id]?.requireSuccessfulReload() }
                            if self.selectedObject == object {
                                if self.isBackgrounded { self.tableError = "修改已提交。使用顶部刷新读取最新数据。" }
                                else { self.loadTable(reloadColumns: true) }
                            }
                        }
                        self.changesByObject[object.id] = changes
                    }
                }
                self.isLoadingTable = false; self.tableTask = nil
            } catch {
                guard let self, self.tableID == id else { return }
                if let fetchedColumns { self.columns = fetchedColumns }
                self.isLoadingTable = false; self.tableTask = nil
                if !(error is CancellationError) { self.tableError = MobileConnectionFeedback.reading(error) }
            }
        }
        tableTask = task
        return task
    }

    /// Adopt only the acknowledged identity change. Reads retain their stable
    /// container and are independently retried through the existing public refresh.
    func acceptCreatedTable(_ object: MobileDatabaseObject) {
        guard selectedDatabase == object.database, catalogKind == .table else { return }
        cancelAll()
        if let catalog {
            var objects = catalog.objects.filter { $0.id != object.id }; objects.append(object)
            self.catalog = .init(objects: MobileCatalogSearch.objects(objects, matching: ""), hasMore: catalog.hasMore)
        }
        search = ""
        _ = selectObject(object)
    }

    func acceptTableAction(_ statement: WorkspaceTableActionStatement, object: MobileDatabaseObject) {
        let affected = selectedObject?.editingSelection == object.editingSelection
        if selectedDatabase == object.database, catalogKind == .table {
            cancelAll()
            if let catalog {
                var objects = catalog.objects.filter { $0.id != object.id }
                if let result = statement.resultingSelection {
                    objects.append(.init(database: result.databaseName, name: object.schemaName == nil ? result.objectName : result.object.nameWithinSchema, kind: .table, comment: object.comment, schemaName: object.schemaName == nil ? nil : result.object.schemaName))
                }
                self.catalog = .init(objects: MobileCatalogSearch.objects(objects, matching: ""), hasMore: catalog.hasMore)
            }
        }
        if statement.resultingSelection != object.editingSelection {
            changesByObject.removeValue(forKey: object.id)
            if affected {
                selectedObject = statement.resultingSelection.map { .init(database: $0.databaseName, name: object.schemaName == nil ? $0.objectName : $0.object.nameWithinSchema, kind: .table, comment: object.comment, schemaName: object.schemaName == nil ? nil : $0.object.schemaName) }
                snapshot = nil; columns = nil; readOnlyStructure = nil; dataFilter = .empty; sortColumn = nil
            }
        } else if affected { currentChanges?.requireSuccessfulReload() }
        if affected { tableError = nil; revision = UUID() }
    }

    func invalidateForUncertainTableAction(_ object: MobileDatabaseObject) {
        if selectedObject?.editingSelection == object.editingSelection {
            cancelTable(); currentChanges?.requireSuccessfulReload(); revision = UUID()
            tableError = "表操作结果待核对，使用顶部刷新读取服务器。"
        }
    }

    func refreshAfterTableAction(object: MobileDatabaseObject) async -> String? {
        guard selectedDatabase == object.database, catalogKind == .table else { return nil }
        let warning = "操作已完成，但页面尚未刷新。关闭后使用顶部刷新即可，无需重复执行操作。"
        guard !isBackgrounded else { catalogError = warning; return warning }
        await loadObjects()?.value
        guard selectedDatabase == object.database, catalogKind == .table else { return nil }
        if selectedObject != nil { await loadTable(reloadColumns: true)?.value }
        return catalogError == nil && tableError == nil ? nil : warning
    }

    func acceptTableComment(_ comment: String, for object: MobileDatabaseObject) -> MobileDatabaseObject? {
        guard selectedDatabase == object.database, catalogKind == object.kind else { return nil }
        let updated = MobileDatabaseObject(database: object.database, name: object.name, kind: object.kind, comment: comment)
        if let catalog {
            self.catalog = .init(objects: catalog.objects.map { $0.id == object.id ? updated : $0 }, hasMore: catalog.hasMore)
        }
        if selectedObject?.id == object.id {
            selectedObject = updated
            if let snapshot, snapshot.object.id == object.id {
                self.snapshot = .init(object: updated, preview: snapshot.preview, columns: snapshot.columns, offset: snapshot.offset,
                    pageSize: snapshot.pageSize, hasNextPage: snapshot.hasNextPage, hasStableOrder: snapshot.hasStableOrder,
                    filter: snapshot.filter, sortColumn: snapshot.sortColumn, ascending: snapshot.ascending)
            }
        }
        return updated
    }

    func schemaDidChange(_ object: MobileDatabaseObject) {
        changesByObject[object.id]?.requireSuccessfulReload()
        guard selectedObject?.editingSelection == object.editingSelection else { return }
        cancelTable(); columns = nil; readOnlyStructure = nil; dataFilter = .empty; sortColumn = nil; revision = UUID()
        tableError = "结构已变化，使用顶部刷新读取最新数据。"
    }

    func sqlDidWrite() {
        cancelTable()
        changesByObject.values.forEach { $0.requireSuccessfulReload() }
        if snapshot != nil { tableError = "SQL 已执行写入，使用顶部刷新核对数据与结构。" }
        revision = UUID()
    }

    func sort(by column: String) {
        if sortColumn == column { ascending.toggle() }
        else { sortColumn = column; ascending = true }
        loadTable(offset: 0)
    }

    @discardableResult
    func applyFilter(_ filter: WorkspaceDatabaseDataFilter, objectID: String) throws -> Task<Void, Never>? {
        guard selectedObject?.id == objectID, let columns else { throw MobileQueryError.invalidServerMetadata }
        try MobileTableFilterDraft.validate(filter, columns: columns)
        guard dataFilter != filter || snapshot?.filter != filter || tableError != nil else { return nil }
        dataFilter = filter
        return loadTable(offset: 0)
    }

    func changePageSize(_ size: Int) {
        pageSize = size
        loadTable(offset: 0)
    }

    func cancelTable() {
        schema?.cancelRead()
        tableID = UUID(); tableTask?.cancel(); tableTask = nil; isLoadingTable = false
    }

    func cancelAll() {
        catalogID = UUID(); catalogTask?.cancel(); catalogTask = nil; isLoadingCatalog = false
        cancelTable()
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        guard backgrounded else { return } // Returning never replays a request.
        if isLoadingCatalog { catalogError = MobileConnectionFeedback.paused }
        if isLoadingTable { tableError = MobileConnectionFeedback.paused }
        safetyLock.enable()
        for changes in changesByObject.values { changes.interruptSubmission() }
        cancelAll()
    }
}
