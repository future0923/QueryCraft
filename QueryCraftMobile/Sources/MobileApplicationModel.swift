import Foundation
import Observation

@MainActor @Observable
final class MobileApplicationModel {
    enum WorkspaceTab: Hashable { case tables, query, views }
    private(set) var workspaceTab: WorkspaceTab = .tables
    private(set) var library = MobileLibraryState()
    private(set) var workspace: MobileDatabaseWorkspace?
    private(set) var isWorkspacePresented = false
    private(set) var libraryLoaded = false
    private(set) var isBackgrounded = false
    var message: String?
    var editingConnection: MobileConnectionDraft?
    var passwordPrompt: MobileConnectionProfile?
    var pendingDeletion: MobileConnectionProfile?
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
    @ObservationIgnored private let repository: any MobileLibraryPersisting
    @ObservationIgnored private let passwords: any MobilePasswordStoring
    @ObservationIgnored private let service: any MobileMySQLServicing
    @ObservationIgnored private var sessionPasswords: [UUID: String] = [:]

    init(repository: any MobileLibraryPersisting = MobileLibraryRepository(),
         passwords: any MobilePasswordStoring = MobileKeychainStore(),
         service: any MobileMySQLServicing = MobileMySQLService()) {
        self.repository = repository
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
        let profile = try draft.profile()
        if let active = workspace, active.hasPendingChanges,
           active.profile != profile || active.query.password != draft.password {
            throw MobileDataMutationError.pendingChanges
        }
        let oldPassword = try passwords.password(for: profile.id)
        try passwords.setPassword(profile.remembersPassword ? draft.password : nil, for: profile.id)
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
        sessionPasswords[profile.id] = draft.password
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
            if profile.requiresPassword, password == nil {
                passwordPrompt = profile
                return
            }
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
            workspace = MobileDatabaseWorkspace(profile: profile, password: password, service: service)
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

    func selectTab(_ tab: WorkspaceTab) {
        guard workspaceTab != tab, let workspace else { return }
        if workspace.query.isLoading || workspace.query.isLoadingEditing { workspace.query.cancel() }
        workspaceTab = tab
        if tab == .query { destination = .query }
        else {
            workspace.browser.selectKind(tab == .views ? .view : .table)
            destination = workspace.browser.selectedObject.map(MobileRoute.table)
        }
    }

    func showLibrary() {
        workspace?.cancelAll()
        destination = nil
        isWorkspacePresented = false
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded
        workspace?.setBackgrounded(backgrounded)
    }

    func delete(_ profile: MobileConnectionProfile) throws {
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
        if workspace?.profile.id == profile.id {
            workspace?.cancelAll(); workspace = nil; destination = nil; isWorkspacePresented = false
        }
        pendingDeletion = nil
    }

    func recordQuery(sql: String, database: String, profileID: UUID) {
        guard libraryLoaded, sql.utf8.count <= 16_384 else { return }
        var state = library
        state.history.removeAll { $0.profileID == profileID && $0.database == database && $0.sql == sql }
        state.history.insert(.init(id: UUID(), profileID: profileID, database: database, sql: sql, date: Date()), at: 0)
        state.history = Array(state.history.prefix(50))
        do { try repository.write(state); library = state }
        catch { message = "查询成功，但历史记录保存失败：\(error.localizedDescription)" }
    }

    func restore(_ history: MobileQueryHistoryItem) {
        guard let workspace, workspace.profile.id == history.profileID else { return }
        workspace.query.cancel()
        workspace.query.database = history.database
        workspace.query.sql = history.sql
        isWorkspacePresented = true
        destination = .query
    }

    func refresh() {
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
        guard isWorkspacePresented, let workspace else { return false }
        switch destination {
        case .query: return workspace.query.isLoading
        case .table: return workspace.browser.isLoadingTable || workspace.schema.isLoading
        case nil: return workspace.browser.isLoadingCatalog
        }
    }
}
