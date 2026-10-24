import Foundation
import Observation
import QueryCraftMobileCore

@MainActor @Observable final class MobileResourceModel {
    let profile: MobileConnectionProfile
    let password: String?
    let elasticsearch: MobileElasticsearchWorkspace?
    private let service: any MobileResourceServicing
    private(set) var scopes: [String]?
    private(set) var scope: String?
    private(set) var catalog: [MobileResource]?
    private(set) var redisTree: [RedisKeyTreeNode]?
    private(set) var selected: MobileResource?
    private(set) var details: MobileResourceDetails?
    private(set) var catalogCursor: UInt64 = 0
    private(set) var isLoadingCatalog = false
    private(set) var isLoadingDetails = false
    private(set) var catalogError: String?
    private(set) var detailError: String?
    private(set) var revision = UUID()
    private(set) var offset = 0
    private(set) var isBackgrounded = false
    private(set) var redisEditor: MobileRedisEditor?
    private(set) var redisKeyAction: MobileRedisKeyAction?
    private(set) var redisConsole: MobileRedisConsole?
    private(set) var isRedisConsolePresented = false
    var hasPendingChanges: Bool { elasticsearch?.hasPendingChanges == true || redisEditor != nil || redisKeyAction != nil || isRedisConsolePresented }
    var canManageRedisKeys: Bool { profile.driver == .redis && scope != nil && !isBackgrounded && !hasPendingChanges }
    var canEditRedis: Bool { profile.driver == .redis && selected != nil && selected?.binaryKeyData == nil && details != nil && (details?.redisType.map { [.string, .hash, .list, .set, .sortedSet].contains($0) } ?? false) && !isLoadingDetails && !isBackgrounded }
    var search = ""
    var redisSearchMode = RedisKeySearchMatchMode.contains
    @ObservationIgnored private var loadedSearchMode = RedisKeySearchMatchMode.contains
    var structure = false
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var catalogID = UUID()
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var detailCursor: UInt64 = 0
    @ObservationIgnored private var history: [(Int, UInt64)] = []
    @ObservationIgnored private var loadedSearch = ""
    var canGoBack: Bool { !history.isEmpty && !isLoadingDetails }
    var isLoading: Bool { elasticsearch?.isLoading == true || isLoadingCatalog || isLoadingDetails }
    var visibleResources: [MobileResource] {
        guard profile.driver == .elasticsearch, !search.isEmpty else { return catalog ?? [] }
        return CompletionLabelMatcher.matching(catalog ?? [], query: search, label: \.name)
    }
    init(profile: MobileConnectionProfile, password: String?, service: (any MobileResourceServicing)? = nil) {
        self.profile = profile; self.password = password
        self.elasticsearch = profile.driver == .elasticsearch && service == nil ? MobileElasticsearchWorkspace(profile: profile, password: password) : nil
        self.service = service ?? MobileResourceService(profile: profile, password: password)
    }
    @discardableResult func load() -> Task<Void, Never>? {
        if let elasticsearch { return elasticsearch.loadCatalog() }
        guard !isBackgrounded else { return nil }
        catalogTask?.cancel(); catalogID = UUID()
        let token = catalogID, service = service
        isLoadingCatalog = true; catalogError = nil
        let task = Task { [weak self] in
            do {
                let scopes = try await service.scopes(); try Task.checkCancellation()
                guard let self, self.catalogID == token else { return }
                self.scopes = scopes; self.isLoadingCatalog = false; self.catalogTask = nil
                let preferred = self.profile.driver == .redis
                    ? RedisConnectionConfiguration.databaseIndex(from: self.profile.database).map(String.init) ?? "0"
                    : self.profile.database
                self.selectScope(scopes.contains(preferred) ? preferred : scopes.first)
            } catch {
                guard let self, self.catalogID == token else { return }
                self.isLoadingCatalog = false; self.catalogTask = nil
                if !(error is CancellationError) { self.catalogError = error.localizedDescription }
            }
        }
        catalogTask = task; return task
    }
    func selectScope(_ value: String?) {
        guard !hasPendingChanges, scope != value || catalog == nil else { return }
        cancel(); scope = value; catalog = nil; redisTree = nil; selected = nil; details = nil
        catalogCursor = 0; search = ""; loadedSearch = ""; revision = UUID()
        if value != nil { loadCatalog() }
    }
    @discardableResult func loadCatalog(more: Bool = false) -> Task<Void, Never>? {
        guard !hasPendingChanges, !isBackgrounded, let scope else { return nil }
        guard !more || catalogCursor != 0 && search == loadedSearch && redisSearchMode == loadedSearchMode else { return nil }
        catalogTask?.cancel(); catalogID = UUID()
        let token = catalogID, service = service, cursor = more ? catalogCursor : 0, search = search, mode = redisSearchMode
        if !more, search != loadedSearch || redisSearchMode != loadedSearchMode {
            // The old glob's keys must never be attributed to the new pattern.
            catalog = nil; redisTree = nil; catalogCursor = 0; selected = nil; cancelDetails(); details = nil
        }
        isLoadingCatalog = true; catalogError = nil
        let task = Task { [weak self] in
            do {
                let page = try await service.catalog(scope: scope, cursor: cursor, search: self?.profile.driver == .redis ? mode.scanPattern(for: search) ?? "" : search); try Task.checkCancellation()
                guard let self, self.catalogID == token, self.scope == scope else { return }
                var seen = Set<String>()
                let merged = ((more ? self.catalog ?? [] : []) + page.resources).filter { seen.insert($0.id).inserted }
                guard merged.count <= 10_000, merged.reduce(0, { $0 + $1.name.utf8.count }) <= 8_388_608 else { throw MobileQueryError.resultTooLarge }
                var tree: [RedisKeyTreeNode]?
                if self.profile.driver == .redis {
                    let references = merged.filter { $0.binaryKeyData == nil }.map { RedisKeyReference(databaseIndex: Int(scope) ?? 0, name: $0.name) }
                    if references.allSatisfy({ $0.name.filter { $0 == ":" }.count < 64 }) {
                        tree = await RedisKeyTreeBuilder().build(keys: references, matching: "")
                        try Task.checkCancellation()
                        guard self.catalogID == token, self.scope == scope else { return }
                    }
                }
                self.redisTree = tree
                self.catalog = merged; self.catalogCursor = page.cursor; self.loadedSearch = search; self.loadedSearchMode = mode
                self.isLoadingCatalog = false; self.catalogTask = nil
            } catch {
                guard let self, self.catalogID == token else { return }
                self.isLoadingCatalog = false; self.catalogTask = nil
                if !(error is CancellationError) { self.catalogError = error.localizedDescription }
            }
        }
        catalogTask = task; return task
    }
    func select(_ resource: MobileResource?) {
        guard !hasPendingChanges, selected != resource else { return }
        cancelDetails(); selected = resource; details = nil; detailError = nil; revision = UUID()
        offset = 0; detailCursor = 0; history = []
        if resource != nil { loadDetails() }
    }
    @discardableResult func loadDetails(offset: Int? = nil, cursor: UInt64? = nil, direction: Int = 0, resetHistory: Bool = false) -> Task<Void, Never>? {
        guard !isBackgrounded, let selected, let scope else { return nil }
        detailTask?.cancel(); detailID = UUID()
        let token = detailID, service = service, offset = offset ?? self.offset, cursor = cursor ?? detailCursor
        isLoadingDetails = true; detailError = nil
        let task = Task { [weak self] in
            do {
                let detail = try await service.details(resource: selected, scope: scope, offset: offset, cursor: cursor)
                try Task.checkCancellation()
                guard let self, self.detailID == token, self.selected == selected, self.scope == scope else { return }
                if direction > 0 { self.history.append((self.offset, self.detailCursor)) }
                if direction < 0 { _ = self.history.popLast() }
                if resetHistory { self.history = [] }
                self.details = detail; self.offset = offset; self.detailCursor = cursor
                self.isLoadingDetails = false; self.detailTask = nil; self.revision = UUID()
            } catch {
                guard let self, self.detailID == token else { return }
                self.isLoadingDetails = false; self.detailTask = nil
                if !(error is CancellationError) { self.detailError = error.localizedDescription }
            }
        }
        detailTask = task; return task
    }
    func next() {
        guard !isLoadingDetails, details?.hasNext == true else { return }
        let step = details?.pageStride ?? 100
        loadDetails(offset: offset + step, cursor: details?.nextCursor ?? 0, direction: 1)
    }
    func previous() { guard !isLoadingDetails, let page = history.last else { return }; loadDetails(offset: page.0, cursor: page.1, direction: -1) }
    func refresh() {
        if let elasticsearch { elasticsearch.refresh(); return }
        if isRedisConsolePresented { return }
        if let redisKeyAction { redisKeyAction.verify(); return }
        if let redisEditor { redisEditor.reload(); return }
        if selected != nil { loadDetails() }
        else if scope != nil { loadCatalog() }
        else { load() }
    }
    func cancelDetails() { detailID = UUID(); detailTask?.cancel(); detailTask = nil; isLoadingDetails = false }
    func cancel() { elasticsearch?.cancel(); catalogID = UUID(); catalogTask?.cancel(); catalogTask = nil; isLoadingCatalog = false; cancelDetails() }
    func beginRedisEditing(service: (any MobileRedisMutating)? = nil) {
        guard canEditRedis, !hasPendingChanges, let selected, let scope, let database = Int(scope) else { return }
        let editor = MobileRedisEditor(key: selected.name, database: database, service: service ?? MobileRedisMutationService(profile: profile, password: password))
        editor.didWrite = { [weak self] in self?.loadDetails(offset: 0, cursor: 0, resetHistory: true) }
        redisEditor = editor; editor.reload()
    }
    func closeRedisEditor() {
        guard let redisEditor, redisEditor.canClose else { return }
        redisEditor.close(); self.redisEditor = nil
        if redisEditor.hasSubmittedAttempt { loadDetails(offset: 0, cursor: 0, resetHistory: true) }
        else { loadDetails() }
    }
    func beginRedisKeyCreation(_ type: RedisKeyType, service: (any MobileRedisKeyActing)? = nil) {
        guard canManageRedisKeys, RedisKeyCreationPlan.creatableTypes.contains(type), let scope, let database = Int(scope) else { return }
        cancel()
        redisKeyAction = .init(mode: .create(type), database: database, service: service ?? MobileRedisKeyActionService(profile: profile, password: password))
    }
    func beginRedisKeyRename(_ resource: MobileResource, service: (any MobileRedisKeyActing)? = nil) {
        guard canManageRedisKeys, resource.binaryKeyData == nil, let scope, let database = Int(scope) else { return }
        cancel()
        redisKeyAction = .init(mode: .rename(.init(databaseIndex: database, name: resource.name)), database: database, service: service ?? MobileRedisKeyActionService(profile: profile, password: password))
    }
    func beginRedisMetadataAction(_ resource: MobileResource, action: MobileRedisKeyAction.MetadataAction) {
        guard canManageRedisKeys, resource.binaryKeyData == nil, let scope, let database = Int(scope) else { return }
        cancel()
        let type = selected?.name == resource.name ? details?.redisType ?? .unknown : .unknown
        let controller = MobileRedisKeyAction(mode: .metadata(.init(databaseIndex: database, name: resource.name, type: type), action), database: database, service: MobileRedisKeyActionService(profile: profile, password: password))
        redisKeyAction = controller; controller.loadMetadata()
    }
    func closeRedisKeyAction() {
        guard let action = redisKeyAction, action.canClose else { return }
        action.close(); redisKeyAction = nil
        guard action.submitted != nil else {
            if catalog == nil { loadCatalog() }
            if selected != nil && details == nil { loadDetails() }
            return
        }
        // Never insert a guessed destination into a filtered SCAN catalog.
        if let destination = action.verifiedDestination {
            if action.isCreation || action.submitted?.references.first?.name == selected?.name {
                select(.init(name: destination.name, kind: "key"))
            }
        } else if action.submitted?.references.contains(where: { $0.name == selected?.name }) == true {
            // An uncertain rename must not leave the old object's cached data visible.
            cancelDetails(); details = nil; revision = UUID(); loadDetails(offset: 0, cursor: 0, resetHistory: true)
        }
        loadCatalog()
        if action.isMetadata, selected != nil {
            if action.isDeletion || action.verifiedDestination == nil { loadDetails(offset: 0, cursor: 0, resetHistory: true) }
            else { loadDetails() }
        }
    }
    func beginRedisConsole() {
        guard canManageRedisKeys, let scope, let database = Int(scope) else { return }
        cancel()
        if redisConsole == nil || redisConsole?.database != database {
            redisConsole = .init(profile: profile, password: password, database: database, keys: (catalog ?? []).filter { $0.binaryKeyData == nil }.map { .init(databaseIndex: database, name: $0.name) })
        }
        isRedisConsolePresented = true
    }
    func closeRedisConsole() {
        guard let console = redisConsole, console.canClose else { return }
        Task { [weak self] in
            await console.close()
            guard let self else { return }
            self.isRedisConsolePresented = false
            self.loadCatalog()
            if self.selected != nil { self.loadDetails(offset: 0, cursor: 0, resetHistory: true) }
        }
    }
    func setBackgrounded(_ value: Bool) {
        elasticsearch?.setBackgrounded(value)
        isBackgrounded = value; redisEditor?.setBackgrounded(value); redisKeyAction?.setBackgrounded(value); redisConsole?.setBackgrounded(value)
        if value { cancel() }
    }
}
