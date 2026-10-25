import Foundation
import Observation
import QueryCraftMobileCore

@MainActor @Observable
final class MobileTransferModel {
    enum Side: Hashable { case source, target }
    private(set) var profiles: [MobileConnectionProfile]
    @ObservationIgnored private var needsProfileReload = false
    let catalog: DataTransferCatalog
    let manager: DataTransferManager
    let library: DataTransferLibraryStore
    let safetyLock = WorkspaceSafetyLock()
    var configuration = DataTransferConfiguration() { didSet { if oldValue != configuration { invalidatePreview() } } }
    var taskName = "新建传输任务"
    var taskFolderID: UUID?
    var activeTaskID: UUID?
    var ownership = TransferOwnership.preserve { didSet { if oldValue != ownership { invalidatePreview() } } }
    var search = ""
    var bulkNames = ""
    var bulkFeedback = ""
    @ObservationIgnored private var savedConfiguration: DataTransferConfiguration?
    @ObservationIgnored private var savedName = ""
    @ObservationIgnored private var savedFolderID: UUID?
    var isDirty: Bool {
        if let savedConfiguration { return configuration != savedConfiguration || taskName != savedName || taskFolderID != savedFolderID }
        return configuration.source.profileID != nil || configuration.target.profileID != nil || !configuration.objects.isEmpty
    }
    private(set) var sourceDatabases: [String] = []
    private(set) var targetDatabases: [String] = []
    private(set) var sourceSchemas: [String] = []
    private(set) var targetSchemas: [String] = []
    private(set) var objects: [TransferObject] = []
    private(set) var sourceLoaded = false
    private(set) var loadingSides: Set<Side> = []
    private(set) var isPreparing = false
    private(set) var isBackgrounded = false
    var message: String?
    var preview: DataTransferPlan?
    var showingPreview = false
    var credentialRequest: MobileConnectionProfile?
    @ObservationIgnored var allowsWrites: () -> Bool = { true }
    @ObservationIgnored private let resolve: (UUID, String?) throws -> DatabaseConnectionConfiguration
    @ObservationIgnored private var passwords: [UUID: String] = [:]
    @ObservationIgnored private var loaders: [Side: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [Side: UUID] = [:]
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var preparationID = UUID()
    private struct CredentialRequest {
        let profileID: UUID
        let side: Side
        let preserveSelection: Bool
    }
    @ObservationIgnored private var credentialSide: Side?
    @ObservationIgnored private var credentialPreservesSelection = false
    @ObservationIgnored private var credentialQueue: [CredentialRequest] = []
    init(profiles: [MobileConnectionProfile], catalog: DataTransferCatalog = .init(), manager: DataTransferManager,
         library: DataTransferLibraryStore = .init(), resolve: @escaping (UUID, String?) throws -> DatabaseConnectionConfiguration) {
        self.profiles = profiles; self.catalog = catalog; self.manager = manager; self.library = library; self.resolve = resolve
    }
    var hasUnverifiedRuns: Bool { manager.runs.contains { [.uncertain, .interrupted].contains($0.status) && $0.verifiedAt == nil } }
    var blocksWrites: Bool { manager.hasActiveRuns || hasUnverifiedRuns }
    var sourceType: DatabaseType? { profileType(configuration.source.profileID) }
    var targetType: DatabaseType? { profileType(configuration.target.profileID) }
    var visibleObjects: [TransferObject] { TransferObjectSelection.filtered(objects, search: search) }
    var canPrepare: Bool { !isBackgrounded && !isPreparing && loadingSides.isEmpty && sourceLoaded && !configuration.objects.isEmpty && !blocksWrites }
    private func profileType(_ id: UUID?) -> DatabaseType? {
        guard let profile = profiles.first(where: { $0.id == id }), profile.driver.isSQL else { return nil }
        return profile.configuration(password: nil).sharedConfiguration.databaseType
    }
    func endpoint(_ side: Side) -> TransferEndpoint { side == .source ? configuration.source : configuration.target }
    private func setEndpoint(_ value: TransferEndpoint, side: Side) {
        if side == .source { configuration.source = value } else { configuration.target = value }
    }
    func chooseProfile(_ id: UUID?, side: Side) {
        let profile = profiles.first { $0.id == id }
        setEndpoint(.init(profileID: id, database: profile?.database ?? "", schema: profile?.schemaName ?? ""), side: side)
        if side == .source { sourceDatabases = []; sourceSchemas = []; objects = []; sourceLoaded = false; configuration.objects = []; configuration.tableFilters = [:] }
        else { targetDatabases = []; targetSchemas = [] }
        if side == .target { pruneSelection() }
        reload(side)
    }
    func chooseDatabase(_ value: String, side: Side) {
        var endpoint = endpoint(side); endpoint.database = value; endpoint.schema = ""; setEndpoint(endpoint, side: side); reload(side)
    }
    func chooseSchema(_ value: String, side: Side) {
        var endpoint = endpoint(side); endpoint.schema = value; setEndpoint(endpoint, side: side); reload(side)
    }
    func supplyPassword(_ value: String) {
        guard let profile = credentialRequest, let side = credentialSide else { return }
        let preserve = credentialPreservesSelection
        passwords[profile.id] = value; credentialRequest = nil; credentialSide = nil
        reload(side, preserveSelection: preserve)
    }
    func cancelCredentialPrompt() { credentialRequest = nil; credentialSide = nil }
    func presentNextCredential() {
        guard credentialRequest == nil, !isBackgrounded else { return }
        while !credentialQueue.isEmpty {
            let request = credentialQueue.removeFirst()
            guard endpoint(request.side).profileID == request.profileID else { continue }
            if passwords[request.profileID] != nil { reload(request.side, preserveSelection: request.preserveSelection); continue }
            credentialSide = request.side; credentialPreservesSelection = request.preserveSelection
            credentialRequest = profiles.first { $0.id == request.profileID }
            if credentialRequest != nil { return }
        }
    }
    private func connection(_ endpoint: TransferEndpoint) throws -> TransferConnection {
        guard let id = endpoint.profileID else { throw MobileQueryError.invalidConnection }
        return .init(endpoint: endpoint, configuration: try resolve(id, passwords[id]).selecting(database: endpoint.database.isEmpty ? nil : endpoint.database))
    }
    @discardableResult
    func reload(_ side: Side, preserveSelection: Bool = false) -> Task<Void, Never>? {
        invalidatePreview(); loaders[side]?.cancel()
        let generation = UUID(), requested = endpoint(side), selected = configuration.objects
        generations[side] = generation
        // Match the desktop workbench: namespace changes invalidate the old
        // catalog immediately; an explicit same-context refresh retains it.
        if side == .source, !preserveSelection || requested.profileID == nil {
            objects = []; sourceLoaded = false
            if !preserveSelection { configuration.objects = []; configuration.tableFilters = [:] }
        }
        guard !isBackgrounded, requested.profileID != nil else {
            loadingSides.remove(side)
            if requested.profileID == nil {
                if side == .source { sourceDatabases = []; sourceSchemas = [] }
                else { targetDatabases = []; targetSchemas = [] }
            }
            return nil
        }
        loadingSides.insert(side); message = nil
        let task = Task { [weak self, catalog] in
            guard let self else { return }
            do {
                let initial = try self.connection(requested)
                let databases = try await catalog.databases(initial.configuration)
                try Task.checkCancellation()
                var endpoint = requested
                if !databases.contains(endpoint.database) { endpoint.database = databases.first ?? ""; endpoint.schema = "" }
                guard !endpoint.database.isEmpty else { throw TransferFailure("没有可用数据库。", "No databases are available.") }
                var connection = TransferConnection(endpoint: endpoint, configuration: initial.configuration.selecting(database: endpoint.database))
                let schemas = initial.type == .postgresql ? try await catalog.schemas(connection) : []
                if initial.type == .postgresql, !schemas.contains(endpoint.schema) { endpoint.schema = schemas.contains("public") ? "public" : schemas.first ?? "" }
                if initial.type == .postgresql, endpoint.schema.isEmpty { throw TransferFailure("没有可用 Schema。", "No schemas are available.") }
                connection = .init(endpoint: endpoint, configuration: connection.configuration)
                let objects = side == .source ? try await catalog.objects(connection) : []
                try Task.checkCancellation()
                guard self.generations[side] == generation else { return }
                self.setEndpoint(endpoint, side: side)
                if side == .source {
                    self.sourceDatabases = databases; self.sourceSchemas = schemas; self.objects = objects; self.sourceLoaded = true
                    self.configuration.objects = preserveSelection ? selected.filter { objects.contains($0) } : []
                    if preserveSelection {
                        let missing = selected.filter { !objects.contains($0) }
                        if !missing.isEmpty { self.message = "部分保存的对象不存在或已重建，请重新勾选：" + missing.map(\.name).joined(separator: ", ") }
                    }
                } else { self.targetDatabases = databases; self.targetSchemas = schemas }
                self.loadingSides.remove(side); self.loaders[side] = nil
            } catch {
                guard self.generations[side] == generation else { return }
                self.loadingSides.remove(side); self.loaders[side] = nil
                if case let MobileTransferCredentialError.passwordRequired(id) = error {
                    self.credentialQueue.removeAll { $0.side == side }
                    self.credentialQueue.append(.init(profileID: id, side: side, preserveSelection: preserveSelection))
                    self.presentNextCredential()
                } else if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
        loaders[side] = task
        return task
    }
    func objectEnabled(_ object: TransferObject) -> Bool {
        TransferCapabilities.objectEnabled(object, content: configuration.content, source: sourceType, target: targetType)
    }
    func pruneSelection() {
        configuration.pruneSelection(sourceType: sourceType, targetType: targetType)
        invalidatePreview()
    }
    func swap() {
        configuration.swapEndpoints(); objects = []; sourceLoaded = false
        sourceDatabases = []; sourceSchemas = []; targetDatabases = []; targetSchemas = []
        credentialQueue = []; cancelCredentialPrompt()
        reload(.source); reload(.target)
    }
    func updateProfiles(_ values: [MobileConnectionProfile], force: Bool = false, reload: Bool = false) {
        if profiles != values || force {
            profiles = values; passwords = [:]; credentialQueue = []; cancelCredentialPrompt()
            invalidatePreview(); needsProfileReload = true
            for side in [Side.source, .target] { generations[side] = UUID(); loaders[side]?.cancel(); loaders[side] = nil }
            loadingSides = []; sourceLoaded = false; objects = []
            sourceDatabases = []; sourceSchemas = []; targetDatabases = []; targetSchemas = []
            if !values.contains(where: { $0.id == configuration.source.profileID }) { configuration.source.profileID = nil }
            if !values.contains(where: { $0.id == configuration.target.profileID }) { configuration.target.profileID = nil }
            pruneSelection()
        }
        if reload, needsProfileReload {
            needsProfileReload = false
            self.reload(.source, preserveSelection: true); self.reload(.target)
        }
    }
    func select(_ object: TransferObject, enabled: Bool) {
        configuration.objects.removeAll { $0.id == object.id }
        if enabled, objectEnabled(object) { configuration.objects.append(object) }
    }
    @discardableResult
    func prepare() -> Task<Void, Never>? {
        guard canPrepare else { return nil }
        invalidatePreview()
        let id = preparationID, captured = configuration, ownership = ownership
        isPreparing = true; message = nil
        let task = Task { [weak self, catalog] in
            guard let self else { return }
            do {
                let source = try self.connection(captured.source), target = try self.connection(captured.target)
                let plan = try await DataTransferPlanner(catalog: catalog).prepare(configuration: captured, source: source, target: target, ownership: ownership)
                try Task.checkCancellation()
                guard self.preparationID == id, self.configuration == captured, !self.isBackgrounded else { return }
                self.preview = plan; self.showingPreview = true
            } catch { if self.preparationID == id, !(error is CancellationError) { self.message = error.localizedDescription } }
            guard self.preparationID == id else { return }
            self.isPreparing = false; self.preparation = nil
        }
        preparation = task
        return task
    }
    func startReviewedPlan() {
        guard let plan = preview, plan.configuration == configuration, !isBackgrounded, !blocksWrites else { return }
        do {
            guard !safetyLock.isEnabled, allowsWrites() else { throw MobileSQLSessionError.locked }
            // Re-resolve the exact profiles before every write. Password changes,
            // backgrounding or another workspace's pending write invalidate it.
            let source = plan.source, target = plan.target
            try manager.start(plan, name: taskName, sourceLabel: label(source), targetLabel: label(target), authorize: { [weak self] in
                guard let self, !self.isBackgrounded, !self.safetyLock.isEnabled, self.allowsWrites(),
                      try self.connection(source.endpoint).configuration == source.configuration,
                      try self.connection(target.endpoint).configuration == target.configuration else { throw CancellationError() }
            })
            showingPreview = false; preview = nil
        } catch { message = error.localizedDescription }
    }
    func label(_ connection: TransferConnection) -> String {
        let profile = profiles.first { $0.id == connection.endpoint.profileID }
        return "\(profile?.name ?? connection.configuration.host) · \(connection.endpoint.database)" + (connection.endpoint.schema.isEmpty ? "" : "." + connection.endpoint.schema)
    }
    func applyBulkNames() {
        let result = TransferObjectSelection.match(bulkNames, objects: objects, namespace: configuration.source.namespace, enabled: objectEnabled)
        for object in result.objects { select(object, enabled: true) }
        bulkFeedback = result.feedback
    }
    func libraryDidChange() {
        if let id = activeTaskID, let task = library.library.tasks.first(where: { $0.id == id }), taskName == savedName { taskName = task.name; savedName = task.name }
        if let taskFolderID, !library.library.folders.contains(where: { $0.id == taskFolderID }) { self.taskFolderID = nil }
    }
    func saveTask() {
        do {
            activeTaskID = try library.save(id: activeTaskID, name: taskName, folderID: taskFolderID, configuration: configuration)
            savedConfiguration = configuration; savedName = taskName; savedFolderID = taskFolderID
        }
        catch { message = error.localizedDescription }
    }
    func loadTask(_ task: SavedTransferTask?) {
        credentialQueue = []; cancelCredentialPrompt()
        configuration = task?.configuration ?? .init(); taskName = task?.name ?? "新建传输任务"; activeTaskID = task?.id; taskFolderID = task?.folderID
        savedConfiguration = task?.configuration; savedName = taskName; savedFolderID = taskFolderID
        sourceLoaded = false; objects = []; sourceDatabases = []; targetDatabases = []; sourceSchemas = []; targetSchemas = []
        reload(.source, preserveSelection: true); reload(.target)
    }
    func invalidatePreview() {
        preparationID = UUID(); preparation?.cancel(); preparation = nil; isPreparing = false; preview = nil; showingPreview = false
    }
    func background(_ value: Bool) {
        isBackgrounded = value
        if value {
            credentialQueue = []; cancelCredentialPrompt()
            safetyLock.enable(); invalidatePreview()
            for side in [Side.source, .target] { generations[side] = UUID(); loaders[side]?.cancel(); loaders[side] = nil }
            loadingSides = []
            for run in manager.runs where run.status.isActive { manager.cancel(run.id) }
        }
    }
}

enum MobileTransferCredentialError: Error { case passwordRequired(UUID) }
