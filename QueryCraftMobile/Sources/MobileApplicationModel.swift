import Foundation
import Observation
import QueryCraftMobileCore

@MainActor @Observable
final class MobileApplicationModel {
    enum WorkspaceTab: String, Codable, Hashable { case tables, query, views }
    private(set) var workspaceTab: WorkspaceTab = .tables
    private(set) var library = MobileLibraryState()
    private(set) var workspace: MobileDatabaseWorkspace?
    private(set) var resourceWorkspace: MobileResourceModel?
    private(set) var isWorkspacePresented = false
    private(set) var libraryLoaded = false
    private(set) var isBackgrounded = false
    var message: String?
    var editingConnection: MobileConnectionDraft?
    var passwordPrompt: MobileConnectionProfile?
    var pendingDeletion: MobileConnectionProfile?
    var showingTransfer = false
    var showingSettings = false
    private(set) var transferModel: MobileTransferModel?
    let transferManager: DataTransferManager
    var transferBlocksWrites: Bool {
        transferManager.hasActiveRuns || transferManager.runs.contains { [.uncertain, .interrupted].contains($0.status) && $0.verifiedAt == nil }
    }
    var destination: MobileRoute? {
        didSet {
            guard !reconcilingTableAction else { return }
            if case let .table(object) = destination {
                workspaceTab = object.kind == .view ? .views : .tables
                workspace?.browser.selectKind(object.kind)
                workspace?.browser.selectObject(object)
            } else if destination == .query {
                workspaceTab = .query
                workspace?.browser.cancelTable()
            }
            else { workspace?.browser.cancelTable() }
        }
    }
    @ObservationIgnored private var reconcilingTableAction = false
    @ObservationIgnored let repository: any MobileLibraryPersisting
    @ObservationIgnored let workspaceRepository: any MobileWorkspacePersisting
    @ObservationIgnored let passwords: any MobilePasswordStoring
    @ObservationIgnored private let service: any MobileSQLServicing
    @ObservationIgnored var sessionPasswords: [UUID: String] = [:]
    /// Reports connections and saved queries edited on this device to iCloud sync.
    @ObservationIgnored var localChangesDidOccur: ((_ keys: [CloudSyncKey], _ deleted: Bool) -> Void)?

    init(repository: any MobileLibraryPersisting = MobileLibraryRepository(),
         passwords: any MobilePasswordStoring = MobileKeychainStore(),
         service: any MobileSQLServicing = MobileMySQLService(), workspaceRepository: any MobileWorkspacePersisting = MobileWorkspaceRepository(), transferManager: DataTransferManager? = nil) {
        self.transferManager = transferManager ?? .init()
        self.repository = repository
        self.workspaceRepository = workspaceRepository
        self.passwords = passwords
        self.service = service
        reloadLibrary()
    }

    func reloadLibrary() {
        do { library = try repository.load(); libraryLoaded = true; message = nil }
        catch { libraryLoaded = false; message = error.localizedDescription }
    }

    func edit(_ profile: MobileConnectionProfile?) {
        do {
            let password: String?
            if let profile { password = try sessionPasswords[profile.id] ?? passwords.password(for: profile.id) }
            else { password = nil }
            editingConnection = MobileConnectionDraft(profile: profile, password: password ?? "")
            message = nil
        } catch { message = error.localizedDescription }
    }

    func save(_ draft: MobileConnectionDraft) throws {
        guard libraryLoaded else { throw MobileQueryError.invalidConnection }
        guard !transferBlocksWrites else { throw MobileDataMutationError.pendingChanges }
        let profile = try draft.profile()
        if let active = workspace, active.hasPendingChanges,
           active.profile != profile || active.query.password != draft.password {
            throw MobileDataMutationError.pendingChanges
        }
        if let active = resourceWorkspace, active.hasPendingChanges,
           active.profile.id == profile.id {
            throw MobileDataMutationError.pendingChanges
        }
        try persistActiveWorkspace()
        let oldPassword = try passwords.password(for: profile.id)
        try passwords.setPassword(profile.remembersPassword && profile.authentication != .none ? draft.password : nil, for: profile.id)
        var state = library
        if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[index] = profile }
        else { state.profiles.append(profile) }
        do { try repository.write(state) }
        catch {
            do { try passwords.setPassword(oldPassword, for: profile.id) }
            catch { message = "连接保存失败，钥匙串恢复也失败。请重新输入该连接的密码。" }
            throw error
        }
        library = state
        transferModel?.updateProfiles(state.profiles, force: true)
        sessionPasswords[profile.id] = draft.password
        localChangesDidOccur?([.init(entity: .connection, id: profile.id)], false)
        editingConnection = nil
        open(profile)
    }

    func open(_ profile: MobileConnectionProfile, suppliedPassword: String? = nil) {
        do {
            let password = try suppliedPassword ?? sessionPasswords[profile.id] ?? passwords.password(for: profile.id)
            if let active = workspace, active.hasPendingChanges,
               active.profile != profile || active.query.password != (password ?? "") {
                throw MobileDataMutationError.pendingChanges
            }
            if let active = resourceWorkspace, active.hasPendingChanges,
               active.profile != profile || active.password != password {
                throw MobileDataMutationError.pendingChanges
            }
            if profile.requiresPassword, password == nil {
                passwordPrompt = profile
                return
            }
            try persistActiveWorkspace()
            if !profile.driver.isSQL {
                if let active = resourceWorkspace, active.profile == profile, active.password == password {
                    isWorkspacePresented = true; passwordPrompt = nil; message = nil
                    if active.scopes == nil { active.load() }
                    else if active.catalog == nil || active.catalogError != nil { active.loadCatalog() }
                    return
                }
                workspace?.cancelAll(); workspace = nil; destination = nil
                resourceWorkspace?.cancel()
                let model = MobileResourceModel(profile: profile, password: password)
                model.setBackgrounded(isBackgrounded)
                resourceWorkspace = model; isWorkspacePresented = true
                if let password { sessionPasswords[profile.id] = password }
                passwordPrompt = nil; message = nil; model.load()
                return
            }
            resourceWorkspace?.cancel(); resourceWorkspace = nil
            if let active = workspace, active.profile == profile, active.query.password == (password ?? "") {
                workspaceTab = .tables
                active.browser.selectKind(.table)
                destination = nil
                isWorkspacePresented = true
                passwordPrompt = nil; message = nil
                if active.browser.databases == nil { active.browser.loadDatabases() }
                else if active.browser.catalog == nil || active.browser.catalogError != nil { active.browser.loadObjects() }
                return
            }
            workspace?.cancelAll()
            destination = nil
            if let password { sessionPasswords[profile.id] = password }
            workspaceTab = .tables
            workspace = MobileDatabaseWorkspace(profile: profile, password: password, service: service, workspaceRepository: workspaceRepository)
            if let restored = workspace.flatMap({ WorkspaceTab(rawValue: $0.navigationMode) }) { workspaceTab = restored }
            if workspaceTab == .query { destination = .query }
            workspace?.browser.didRestoreSelection = { [weak self] object in
                guard let self, self.workspaceTab != .query else { return }
                self.reconcilingTableAction = true; self.destination = .table(object); self.reconcilingTableAction = false
            }
            workspace?.externalWriteFence = { [weak self] in self?.transferBlocksWrites ?? true }
            workspace?.tableMetadataDidChange = { [weak self] object in
                guard let self, self.isWorkspacePresented, self.workspace?.profile.id == profile.id,
                      case .table(let selected) = self.destination, selected.editingSelection == object.editingSelection else { return }
                self.reconcilingTableAction = true; self.destination = .table(object); self.reconcilingTableAction = false
            }
            workspace?.tableDidCreate = { [weak self] object in
                guard let self, self.isWorkspacePresented, self.workspace?.profile.id == profile.id else { return }
                self.workspaceTab = .tables; self.destination = .table(object)
            }
            workspace?.savedQueriesDidChange = { [weak self] changed, deleted in
                self?.localChangesDidOccur?(changed.map { .init(entity: .savedQuery, id: $0) }, false)
                self?.localChangesDidOccur?(deleted.map { .init(entity: .savedQuery, id: $0) }, true)
            }
            workspace?.didExecuteQuery = { [weak self] sql, database, schema in
                self?.recordQuery(sql: sql, database: database, profileID: profile.id, schemaName: schema)
            }
            workspace?.tableDidChange = { [weak self] object, statement in
                guard let self, self.isWorkspacePresented, let workspace = self.workspace,
                      case .table(let current) = self.destination,
                      current.editingSelection == object.editingSelection || current.editingSelection == statement.resultingSelection else { return }
                self.reconcilingTableAction = true
                self.destination = workspace.browser.selectedObject.map(MobileRoute.table)
                self.reconcilingTableAction = false
            }
            workspace?.setBackgrounded(isBackgrounded)
            isWorkspacePresented = true
            passwordPrompt = nil; message = nil
            workspace?.browser.loadDatabases()
        } catch { message = error.localizedDescription }
    }

    func openTransfer() {
        if transferModel == nil {
            let model = MobileTransferModel(profiles: library.profiles, manager: transferManager, resolve: { [weak self] id, override in
                guard let self, let profile = self.library.profiles.first(where: { $0.id == id }), profile.driver.isSQL else { throw MobileQueryError.invalidConnection }
                let secret = try override ?? self.sessionPasswords[id] ?? self.passwords.password(for: id)
                if profile.requiresPassword, secret == nil { throw MobileTransferCredentialError.passwordRequired(id) }
                return profile.configuration(password: secret).sharedConfiguration
            })
            model.allowsWrites = { [weak self] in
                guard let self else { return false }
                return !self.isBackgrounded && self.workspace?.hasPendingChanges != true && self.resourceWorkspace?.hasPendingChanges != true
            }
            model.background(isBackgrounded)
            transferModel = model
        }
        transferModel?.updateProfiles(library.profiles, reload: true)
        showingTransfer = true
    }

    func selectTab(_ tab: WorkspaceTab) {
        guard workspaceTab != tab, let workspace else { return }
        if workspace.query.isLoading || workspace.query.isLoadingEditing { workspace.query.cancel() }
        workspaceTab = tab
        workspace.navigationMode = tab.rawValue
        workspace.persistWorkspace()
        if tab == .query { destination = .query }
        else {
            workspace.browser.selectKind(tab == .views ? .view : .table)
            destination = workspace.browser.selectedObject.map(MobileRoute.table)
        }
    }

    private func persistActiveWorkspace() throws {
        if let workspace, !workspace.persistWorkspace() { throw CocoaError(.fileWriteUnknown) }
    }

    func showLibrary() {
        do { try persistActiveWorkspace() } catch { message = workspace?.documentMessage ?? error.localizedDescription; return }
        workspace?.cancelAll(); resourceWorkspace?.cancel()
        destination = nil
        isWorkspacePresented = false
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        transferModel?.background(backgrounded)
        if backgrounded { for run in transferManager.runs where run.status.isActive { transferManager.cancel(run.id) } }
        workspace?.setBackgrounded(backgrounded); resourceWorkspace?.setBackgrounded(backgrounded)
    }

    func delete(_ profile: MobileConnectionProfile) throws {
        guard !transferBlocksWrites else { throw MobileDataMutationError.pendingChanges }
        if resourceWorkspace?.profile.id == profile.id, resourceWorkspace?.hasPendingChanges == true {
            throw MobileDataMutationError.pendingChanges
        }
        if workspace?.profile.id == profile.id, workspace?.hasPendingChanges == true {
            throw MobileDataMutationError.pendingChanges
        }
        var state = library
        state.profiles.removeAll { $0.id == profile.id }
        state.history.removeAll { $0.profileID == profile.id }
        let oldPassword = try passwords.password(for: profile.id)
        try passwords.setPassword(nil, for: profile.id)
        do { try repository.write(state) }
        catch { try? passwords.setPassword(oldPassword, for: profile.id); throw error }
        library = state; sessionPasswords[profile.id] = nil
        transferModel?.updateProfiles(state.profiles, force: true)
        if workspace?.profile.id == profile.id {
            workspace?.cancelAll(); workspace = nil; destination = nil; isWorkspacePresented = false
        }
        if resourceWorkspace?.profile.id == profile.id { resourceWorkspace?.cancel(); resourceWorkspace = nil; isWorkspacePresented = false }
        pendingDeletion = nil
        let savedQueryIDs = (try? workspaceRepository.load(profileID: profile.id))?.savedQueries.map(\.id) ?? []
        localChangesDidOccur?([.init(entity: .connection, id: profile.id)], true)
        localChangesDidOccur?(savedQueryIDs.map { .init(entity: .savedQuery, id: $0) }, true)
        do { try workspaceRepository.remove(profileID: profile.id) }
        catch { message = "连接已删除，但工作区文件清理失败：\(error.localizedDescription)" }
    }

    // MARK: iCloud sync

    /// Applies connections received from iCloud without reporting them back
    /// as local edits. Passwords follow the connection; a deleted connection
    /// also drops its workspace unless it is open with unsaved work.
    func applyCloudConnections(_ upserts: [CloudSyncConnection], deletions: Set<UUID>) throws {
        guard libraryLoaded else { throw CocoaError(.fileReadCorruptFile) }
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        var state = library
        var secrets: [(UUID, String?)] = []
        for connection in upserts {
            let existing = state.profiles.first { $0.id == connection.id }
            guard let driver = MobileDriver(rawValue: connection.databaseType),
                  let tlsMode = ConnectionTLSMode(rawValue: connection.tlsMode),
                  (1...65_535).contains(connection.port),
                  !connection.name.isEmpty, !connection.host.isEmpty else { continue }
            let authentication = MobileAuthentication(rawValue: connection.authenticationMethod) ?? .usernamePassword
            let remembers = connection.storesCredential && authentication != .none
            let requiresPassword: Bool
            switch connection.secret {
            case let .value(secret) where remembers:
                secrets.append((connection.id, secret)); requiresPassword = !secret.isEmpty
            case .unavailable where remembers:
                requiresPassword = existing?.requiresPassword ?? true
            default:
                secrets.append((connection.id, nil)); requiresPassword = !remembers && authentication != .none
            }
            let profile = MobileConnectionProfile(
                id: connection.id, name: connection.name, host: connection.host, port: connection.port,
                username: connection.username,
                database: connection.defaultDatabase ?? (driver == .milvus ? "default" : ""),
                tlsMode: tlsMode, remembersPassword: remembers, requiresPassword: requiresPassword,
                driver: driver, authentication: authentication, schemaName: connection.mobile?.schemaName)
            if let index = state.profiles.firstIndex(where: { $0.id == profile.id }) { state.profiles[index] = profile }
            else { state.profiles.append(profile) }
        }
        let removed = state.profiles.filter { deletions.contains($0.id) }.map(\.id)
        state.profiles.removeAll { deletions.contains($0.id) }
        state.history.removeAll { deletions.contains($0.profileID) }
        try repository.write(state)
        library = state
        for (id, secret) in secrets {
            try? passwords.setPassword(secret, for: id)
            sessionPasswords[id] = nil
        }
        transferModel?.updateProfiles(state.profiles, force: true)
        for id in removed {
            try? passwords.setPassword(nil, for: id)
            sessionPasswords[id] = nil
            if workspace?.profile.id == id {
                guard workspace?.hasPendingChanges != true else { continue }
                workspace?.cancelAll(); workspace = nil; destination = nil; isWorkspacePresented = false
            }
            if resourceWorkspace?.profile.id == id {
                guard resourceWorkspace?.hasPendingChanges != true else { continue }
                resourceWorkspace?.cancel(); resourceWorkspace = nil; isWorkspacePresented = false
            }
            try? workspaceRepository.remove(profileID: id)
        }
    }

    /// Saved queries for a connection, from the open workspace when there is
    /// one so unsaved in-memory state is never overwritten.
    func cloudSavedQueries(profileID: UUID) -> [SavedQuery] {
        if let workspace, workspace.profile.id == profileID { return workspace.savedQueries }
        return (try? workspaceRepository.load(profileID: profileID))?.savedQueries ?? []
    }

    /// Applies saved queries received from iCloud. Returns the queries whose
    /// connection is not on this device yet.
    func applyCloudSavedQueries(_ upserts: [SavedQuery], deletions: Set<UUID>) throws -> [SavedQuery] {
        let known = Set(library.profiles.map(\.id))
        let waiting = upserts.filter { !known.contains($0.connectionProfileID) }
        var byProfile: [UUID: (upserts: [SavedQuery], deletions: Set<UUID>)] = [:]
        for query in upserts where known.contains(query.connectionProfileID) && query.sql.utf8.count <= 262_144 {
            byProfile[query.connectionProfileID, default: ([], [])].upserts.append(query)
        }
        if !deletions.isEmpty {
            for profileID in known where cloudSavedQueries(profileID: profileID).contains(where: { deletions.contains($0.id) }) {
                byProfile[profileID, default: ([], [])].deletions.formUnion(deletions)
            }
        }
        for (profileID, change) in byProfile {
            // A query moved to another connection is removed from the old one.
            let moved = Set(change.upserts.map(\.id))
            for other in known where other != profileID
                && cloudSavedQueries(profileID: other).contains(where: { moved.contains($0.id) }) {
                byProfile[other, default: ([], [])].deletions.formUnion(moved)
            }
        }
        for (profileID, change) in byProfile {
            if let workspace, workspace.profile.id == profileID {
                guard workspace.applyRemoteSavedQueries(upserts: change.upserts, deletions: change.deletions) else {
                    throw MobileWorkspaceRepository.Failure.invalidArchive
                }
                continue
            }
            var archive = try workspaceRepository.load(profileID: profileID) ?? MobileWorkspaceArchive(profileID: profileID)
            let replaced = Set(change.upserts.map(\.id)).union(change.deletions)
            archive.savedQueries.removeAll { replaced.contains($0.id) }
            archive.savedQueries.append(contentsOf: change.upserts)
            for index in archive.documents.indices where archive.documents[index].metadata.savedQueryID.map(change.deletions.contains) == true {
                let item = archive.documents[index]
                archive.documents[index] = .init(
                    metadata: .init(id: item.metadata.id, title: item.metadata.title, savedQueryID: nil,
                                    defaultDatabase: item.metadata.defaultDatabase,
                                    resultRowLimit: item.metadata.resultRowLimit),
                    draft: item.draft, schemaName: item.schemaName, selectionLocation: item.selectionLocation,
                    selectionLength: item.selectionLength, needsWriteVerification: item.needsWriteVerification)
            }
            try workspaceRepository.write(archive)
        }
        return waiting
    }

    func recordQuery(sql: String, database: String, profileID: UUID, schemaName: String? = nil) {
        guard libraryLoaded, sql.utf8.count <= 16_384 else { return }
        var state = library
        state.history.removeAll { $0.profileID == profileID && $0.database == database && $0.schemaName == schemaName && $0.sql == sql }
        state.history.insert(.init(id: UUID(), profileID: profileID, database: database, sql: sql, date: Date(), schemaName: schemaName), at: 0)
        state.history = Array(state.history.prefix(50))
        do { try repository.write(state); library = state }
        catch { message = "查询成功，但历史记录保存失败：\(error.localizedDescription)" }
    }

    func restore(_ history: MobileQueryHistoryItem) {
        guard let workspace, workspace.profile.id == history.profileID else { return }
        guard let document = workspace.newDocument() else { return }
        document.query.database = history.database
        document.query.schemaName = history.schemaName
        document.query.sql = history.sql
        if workspace.profile.driver == .postgresql {
            workspace.browser.selectDatabase(history.database)
            workspace.browser.selectSchema(history.schemaName)
        }
        workspace.navigationMode = WorkspaceTab.query.rawValue
        workspaceTab = .query
        workspace.persistWorkspace()
        isWorkspacePresented = true
        destination = .query
    }

    func refresh() {
        if isWorkspacePresented, let resourceWorkspace { resourceWorkspace.refresh(); return }
        guard isWorkspacePresented, let workspace else { reloadLibrary(); return }
        guard !workspace.tableActions.isSubmitting, !workspace.schema.isSubmitting else { return }
        if workspace.tableActions.unverified != nil { workspace.browser.loadObjects() }
        switch destination {
        case .query: workspace.query.refresh()
        case .table: workspace.browser.loadTable(reloadColumns: true)
        case nil:
            if workspace.browser.selectedDatabase == nil { workspace.browser.loadDatabases() }
            else { workspace.browser.loadObjects() }
        }
    }

    var isLoading: Bool {
        if isWorkspacePresented, let resourceWorkspace { return resourceWorkspace.isLoading }
        guard isWorkspacePresented, let workspace else { return false }
        switch destination {
        case .query: return workspace.query.isLoading
        case .table: return workspace.browser.isLoadingTable || workspace.schema.isLoading
        case nil: return workspace.browser.isLoadingCatalog
        }
    }
}
