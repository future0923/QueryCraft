import AppKit
import Observation

@MainActor @Observable
final class DataTransferWorkbenchModel {
    enum Side: Hashable { case source, target }
    let library: DataTransferLibraryStore
    let manager: DataTransferManager
    var configuration = DataTransferConfiguration()
    var taskName = AppCopy.current.text("新建传输任务", "New transfer task")
    var taskFolderID: UUID?
    private(set) var activeTaskID: UUID?
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var sourceDatabases: [String] = []
    private(set) var targetDatabases: [String] = []
    private(set) var sourceSchemas: [String] = []
    private(set) var targetSchemas: [String] = []
    private(set) var objects: [TransferObject] = []
    private(set) var sourceLoaded = false
    private(set) var loadingSides: Set<Side> = []
    private(set) var isPreparing = false
    var errorMessage = ""
    var statusMessage = ""
    var objectSearch = ""
    var taskSearch = ""
    var bulkNames = ""
    var bulkFeedback = ""
    var ownership = TransferOwnership.preserve
    var preview: DataTransferPlan?
    var showingPreview = false
    var showingHistory = false
    var showingDiscard = false
    var filterObject: TransferObject?
    var filterDraft = ""
    @ObservationIgnored private var savedConfiguration: DataTransferConfiguration?
    @ObservationIgnored private var savedName = ""
    @ObservationIgnored private var savedFolderID: UUID?
    @ObservationIgnored private var pendingSelection: SavedTransferTask?
    @ObservationIgnored private var pendingNew = false
    @ObservationIgnored private let repository: any ConnectionProfileRepository
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored let catalog: DataTransferCatalog
    @ObservationIgnored private var passwords: [UUID: String] = [:]
    @ObservationIgnored private var loaders: [Side: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [Side: UUID] = [:]
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var preparationID = UUID()

    init(library: DataTransferLibraryStore = .init(), manager: DataTransferManager = .shared,
         repository: any ConnectionProfileRepository = SQLiteConnectionProfileRepository(),
         credentials: any CredentialStore = KeychainCredentialStore(), catalog: DataTransferCatalog = .init()) {
        self.library = library; self.manager = manager; self.repository = repository; self.credentials = credentials; self.catalog = catalog
    }

    var isDirty: Bool {
        if let savedConfiguration { return configuration != savedConfiguration || taskName != savedName || taskFolderID != savedFolderID }
        return configuration.source.profileID != nil || configuration.target.profileID != nil || !configuration.objects.isEmpty
    }
    var sourceType: DatabaseType? { profiles.first { $0.id == configuration.source.profileID }?.databaseType }
    var targetType: DatabaseType? { profiles.first { $0.id == configuration.target.profileID }?.databaseType }
    var filteredObjects: [TransferObject] {
        TransferObjectSelection.filtered(objects, search: objectSearch)
    }
    var canPrepare: Bool {
        !isPreparing && loadingSides.isEmpty && !configuration.objects.isEmpty && configuration.source.profileID != nil && configuration.target.profileID != nil
    }

    func loadProfiles() async {
        do {
            await DatabaseDriverManager.shared.loadInstalledDrivers()
            profiles = try await repository.fetchAll()
            if let error = library.loadError { errorMessage = error }
        } catch { errorMessage = error.localizedDescription }
    }

    func endpoint(_ side: Side) -> TransferEndpoint { side == .source ? configuration.source : configuration.target }
    func setEndpoint(_ value: TransferEndpoint, side: Side) {
        if side == .source { configuration.source = value } else { configuration.target = value }
    }
    func chooseProfile(_ id: UUID?, side: Side) {
        invalidatePreview()
        if side == .source { sourceDatabases = []; sourceSchemas = [] } else { targetDatabases = []; targetSchemas = [] }
        let profile = profiles.first { $0.id == id }
        setEndpoint(.init(profileID: id, database: profile?.defaultDatabase ?? "", schema: ""), side: side)
        reload(side, resetDatabase: false)
    }
    func chooseDatabase(_ name: String, side: Side) {
        var value = endpoint(side); value.database = name; value.schema = ""; setEndpoint(value, side: side)
        reload(side, resetDatabase: false)
    }
    func chooseSchema(_ name: String, side: Side) {
        var value = endpoint(side); value.schema = name; setEndpoint(value, side: side)
        reload(side, resetDatabase: false)
    }

    func connection(_ endpoint: TransferEndpoint) async throws -> TransferConnection {
        guard let id = endpoint.profileID, let profile = try await repository.fetch(id: id) else {
            throw TransferFailure("连接不存在，请重新选择。", "Connection no longer exists. Select it again.")
        }
        var secret = passwords[id]
        if secret == nil { secret = try await credentials.password(for: id) }
        if secret == nil && profile.authenticationMethod != .none {
            guard let entered = await NativeWorkspaceCredentialPrompter().requestPassword(for: profile, attachedTo: NSApp.keyWindow) else { throw CancellationError() }
            secret = entered; passwords[id] = entered
        }
        return TransferConnection(endpoint: endpoint, configuration: .init(databaseType: profile.databaseType, databaseProduct: profile.databaseProduct, host: profile.host, port: profile.port, authentication: profile.authentication(secret: secret), database: endpoint.database.isEmpty ? nil : endpoint.database, tlsMode: profile.tlsMode))
    }

    func reload(_ side: Side, resetDatabase: Bool = false, preserveSelection: Bool = false) {
        invalidatePreview(); loaders[side]?.cancel()
        let generation = UUID(); generations[side] = generation
        let value = endpoint(side)
        let selected = preserveSelection ? configuration.objects : []
        if side == .source {
            if !preserveSelection || value.profileID == nil {
                objects = []; sourceLoaded = false
                if !preserveSelection { configuration.objects = []; configuration.tableFilters = [:] }
            }
        }
        guard value.profileID != nil else {
            loadingSides.remove(side)
            if side == .source { sourceDatabases = []; sourceSchemas = [] } else { targetDatabases = []; targetSchemas = [] }
            return
        }
        loadingSides.insert(side); errorMessage = ""
        loaders[side] = Task { [weak self] in
            guard let self else { return }
            do {
                let initial = try await self.connection(value)
                let databases = try await self.catalog.databases(initial.configuration)
                try Task.checkCancellation(); guard self.generations[side] == generation else { return }
                var resolved = value
                if resetDatabase || !databases.contains(resolved.database) { resolved.database = databases.first ?? ""; resolved.schema = "" }
                guard !resolved.database.isEmpty else { throw TransferFailure("连接没有可用数据库。", "No databases are available for this connection.") }
                var connection = TransferConnection(endpoint: resolved, configuration: initial.configuration.selecting(database: resolved.database))
                let schemas = initial.type == .postgresql ? try await self.catalog.schemas(connection) : []
                if initial.type == .postgresql && !schemas.contains(resolved.schema) { resolved.schema = schemas.contains("public") ? "public" : schemas.first ?? "" }
                if initial.type == .postgresql && resolved.schema.isEmpty { throw TransferFailure("没有可用的 Schema。", "No schemas are available.") }
                connection = .init(endpoint: resolved, configuration: connection.configuration)
                let objects = side == .source ? try await self.catalog.objects(connection) : []
                try Task.checkCancellation(); guard self.generations[side] == generation else { return }
                self.setEndpoint(resolved, side: side)
                if side == .source {
                    self.sourceDatabases = databases; self.sourceSchemas = schemas; self.objects = objects; self.sourceLoaded = true
                    if preserveSelection {
                        let missing = selected.filter { !objects.contains($0) }
                        self.configuration.objects = selected.filter { objects.contains($0) }
                        if !missing.isEmpty { self.errorMessage = AppCopy.current.text("部分保存的对象不存在或已重建，请重新勾选：", "Some saved objects are missing or recreated. Select them again: ") + missing.map(\.name).joined(separator: ", ") }
                    }
                } else { self.targetDatabases = databases; self.targetSchemas = schemas }
                self.loadingSides.remove(side)
            } catch {
                guard self.generations[side] == generation else { return }
                self.loadingSides.remove(side)
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func refresh() { reload(.source, preserveSelection: true); reload(.target) }
    func swap() {
        configuration.swapEndpoints()
        reload(.source); reload(.target)
    }
    func objectEnabled(_ object: TransferObject) -> Bool {
        TransferCapabilities.objectEnabled(object, content: configuration.content, source: sourceType, target: targetType)
    }
    func select(_ object: TransferObject, enabled: Bool) {
        invalidatePreview()
        configuration.objects.removeAll { $0.id == object.id }
        if enabled && objectEnabled(object) { configuration.objects.append(object) }
    }
    func selectVisible(_ select: Bool) {
        for object in filteredObjects where objectEnabled(object) { self.select(object, enabled: select) }
    }
    func pruneSelection() {
        configuration.pruneSelection(sourceType: sourceType, targetType: targetType)
        invalidatePreview()
    }
    func applyBulkNames() {
        let result = TransferObjectSelection.match(bulkNames, objects: objects, namespace: configuration.source.namespace, enabled: objectEnabled)
        for object in result.objects { select(object, enabled: true) }
        bulkFeedback = result.feedback
    }

    func save() {
        do {
            activeTaskID = try library.save(id: activeTaskID, name: taskName, folderID: taskFolderID, configuration: configuration)
            savedConfiguration = configuration; savedName = taskName; savedFolderID = taskFolderID
            statusMessage = AppCopy.current.text("配置已保存", "Configuration saved")
        } catch { errorMessage = error.localizedDescription }
    }
    func libraryDidChange() {
        if let id = activeTaskID, let task = library.library.tasks.first(where: { $0.id == id }), taskName == savedName {
            taskName = task.name; savedName = task.name
        }
        if let taskFolderID, !library.library.folders.contains(where: { $0.id == taskFolderID }) { self.taskFolderID = nil }
    }
    func requestTask(_ task: SavedTransferTask?) {
        if isDirty { pendingSelection = task; pendingNew = task == nil; showingDiscard = true }
        else { loadTask(task) }
    }
    func discardAndSwitch() {
        let task = pendingNew ? nil : pendingSelection; pendingSelection = nil; pendingNew = false; showingDiscard = false; loadTask(task)
    }
    private func loadTask(_ task: SavedTransferTask?) {
        invalidatePreview()
        objects = []; sourceLoaded = false; sourceDatabases = []; sourceSchemas = []; targetDatabases = []; targetSchemas = []
        configuration = task?.configuration ?? .init(); activeTaskID = task?.id
        taskName = task?.name ?? AppCopy.current.text("新建传输任务", "New transfer task"); taskFolderID = task?.folderID
        savedConfiguration = task?.configuration; savedName = taskName; savedFolderID = taskFolderID
        ownership = .preserve; statusMessage = ""; errorMessage = ""
        reload(.source, preserveSelection: true); reload(.target)
    }

    func prepare() {
        guard canPrepare else { return }
        invalidatePreview(); isPreparing = true; errorMessage = ""
        let id = UUID(); preparationID = id
        let configuration = configuration, ownership = ownership, catalog = catalog
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.connection(configuration.source)
                let target = try await self.connection(configuration.target)
                let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: configuration, source: source, target: target, ownership: ownership)
                try Task.checkCancellation()
                guard self.preparationID == id, self.configuration == configuration else { return }
                self.preview = plan; self.showingPreview = true; self.isPreparing = false
            } catch {
                guard self.preparationID == id else { return }
                self.isPreparing = false
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }
    func startReviewedPlan() {
        guard let preview, preview.configuration == configuration else { invalidatePreview(); return }
        do {
            let source = profiles.first { $0.id == configuration.source.profileID }?.name ?? ""
            let target = profiles.first { $0.id == configuration.target.profileID }?.name ?? ""
            try manager.start(preview, name: taskName, sourceLabel: source + " / " + configuration.source.database + " / " + configuration.source.schema,
                              targetLabel: target + " / " + configuration.target.database + " / " + configuration.target.schema)
            showingPreview = false; self.preview = nil; showingHistory = true
            statusMessage = AppCopy.current.text("任务已在后台启动。关闭此窗口不会停止传输。", "Transfer started in the background. Closing this window does not stop it.")
        } catch { errorMessage = error.localizedDescription }
    }
    func invalidatePreview() {
        preparation?.cancel(); preparationID = UUID(); isPreparing = false; preview = nil; showingPreview = false
    }
    func cancelPreparation() { invalidatePreview() }
    func close() {
        loaders.values.forEach { $0.cancel() }; loaders.removeAll(); generations.removeAll(); loadingSides.removeAll(); invalidatePreview()
    }
}
