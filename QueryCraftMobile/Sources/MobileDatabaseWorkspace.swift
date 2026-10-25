import Foundation
import Observation

@MainActor @Observable
final class MobileDatabaseWorkspace: Identifiable {
    let id = UUID()
    let profile: MobileConnectionProfile
    private let configuration: MobileSQLConfiguration
    private(set) var query: MobileQueryModel
    private(set) var documents: [MobileSQLDocument] = []
    private(set) var savedQueries: [SavedQuery] = []
    var documentMessage: String?
    var showingDocuments = false
    var recoveryBackupURL: URL?
    var needsArchiveRecovery: Bool { !archiveReadable }
    var navigationMode = "tables"
    @ObservationIgnored var externalWriteFence: () -> Bool = { false }
    @ObservationIgnored var didExecuteQuery: ((String, String, String?) -> Void)?
    @ObservationIgnored private let makeQueryModel: () -> MobileQueryModel
    @ObservationIgnored private let workspaceRepository: any MobileWorkspacePersisting
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var archiveReadable = true
    @ObservationIgnored private var restoringWorkspace = false
    var activeDocument: MobileSQLDocument? { documents.first { $0.query === query } }
    var hasUnverifiedQueryWrites: Bool { documents.contains { $0.query.hasUnverifiedWrites } }
    var queryBlocksWrites: Bool { documents.contains { $0.query.blocksOtherWrites } }
    var queriesHavePendingChanges: Bool { documents.contains { $0.query.hasPendingChanges } }
    var queriesHaveSubmittingChanges: Bool { documents.contains { $0.query.hasSubmittingChanges } }
    func queriesHavePendingChanges(for object: MobileDatabaseObject) -> Bool { documents.contains { $0.query.hasPendingChanges(for: object) } }
    func invalidateQueries(_ object: MobileDatabaseObject? = nil) { documents.forEach { $0.query.tableDidChange(object) } }
    let browser: MobileBrowserModel
    let schema: MobileSchemaController
    let tableActions: MobileTableActionController
    let newTable: MobileNewTableController
    var dataImport: MobileDataImportModel?
    @ObservationIgnored var tableMetadataDidChange: ((MobileDatabaseObject) -> Void)?
    @ObservationIgnored var tableDidCreate: ((MobileDatabaseObject) -> Void)?
    @ObservationIgnored var tableDidChange: ((MobileDatabaseObject, WorkspaceTableActionStatement) -> Void)?

    init(profile: MobileConnectionProfile, password: String?, service: any MobileSQLServicing, tableActionService: any MobileTableActionServicing = MobileTableActionService(), queryExecutor: any MobileQueryExecuting = MobileMariaDBExecutor(), schemaService: any MobileSchemaServicing = MobileSchemaService(), newTableService: any MobileNewTableServicing = MobileNewTableService(), workspaceRepository: any MobileWorkspacePersisting = MobileWorkspaceRepository()) {
        self.workspaceRepository = workspaceRepository
        self.profile = profile; self.configuration = profile.configuration(password: password)
        let service: any MobileSQLServicing = profile.driver == .postgresql ? MobilePostgreSQLService() : profile.driver == .doris ? MobileDorisService() : service
        let queryExecutor: any MobileQueryExecuting = profile.driver == .postgresql ? MobilePostgreSQLExecutor() : profile.driver == .doris ? MobileDorisExecutor() : queryExecutor
        let mutations: any MobileDataMutating = profile.driver == .postgresql ? MobilePostgreSQLMutationService() : MobileDataMutationService()
        browser = MobileBrowserModel(configuration: profile.configuration(password: password), service: service, mutationService: mutations,
                                     supportsEditing: profile.driver == .mysql || profile.driver == .postgresql)
        tableActions = MobileTableActionController(configuration: profile.configuration(password: password), safetyLock: browser.safetyLock, service: profile.driver == .postgresql ? MobilePostgreSQLTableActionService() : tableActionService)
        schema = MobileSchemaController(configuration: profile.configuration(password: password), safetyLock: browser.safetyLock, service: profile.driver == .postgresql ? MobilePostgreSQLSchemaService() : schemaService)
        newTable = MobileNewTableController(configuration: profile.configuration(password: password), safetyLock: browser.safetyLock, service: profile.driver == .postgresql ? MobilePostgreSQLNewTableService() : newTableService)
        browser.schema = (profile.driver == .mysql || profile.driver == .postgresql) ? schema : nil
        makeQueryModel = { [safetyLock = browser.safetyLock] in
            let query = MobileQueryModel(executor: queryExecutor, metadataService: service, mutationService: mutations, safetyLock: safetyLock)
        query.driver = profile.driver
        query.schemaName = profile.schemaName
        query.exportDialect = profile.driver == .postgresql ? .postgresql : profile.driver == .doris ? .doris : .mysql
        query.host = profile.host
        query.port = String(profile.port)
        query.username = profile.username
        query.password = password ?? ""
        query.database = profile.database
        query.tlsMode = profile.tlsMode
            return query
        }
        query = makeQueryModel()
        documents = [.init(title: "查询 1", query: query)]
        if profile.driver == .postgresql { tableActions.onImport = { [weak self] object in self?.openImport(object) } }
        browser.allowsDatabaseChange = { [weak self] in self?.queriesHavePendingChanges == false }
        tableActions.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        tableActions.isCurrent = { [weak browser] draft in
            browser?.selectedDatabase == draft.object.database && browser?.contextID == draft.contextID && browser?.isBackgrounded == false
        }
        tableActions.hasPendingChanges = { [weak self] object in
            guard let self else { return true }
            let table = self.browser.changesByObject[object.id]
            return self.externalWriteFence() || self.dataImport?.blocksWrites == true || self.queryBlocksWrites || self.newTable.blocksWrites || self.schema.drafts[object.id]?.hasChanges == true || self.schema.blocksWrites || table?.hasChanges == true || self.queriesHavePendingChanges(for: object)
                || self.browser.changesByObject.values.contains { $0.isSubmitting } || self.queriesHaveSubmittingChanges
        }
        browser.allowsDataMutation = { [weak self] in
            guard let self else { return false }
            return !self.externalWriteFence() && (self.profile.driver == .mysql || self.profile.driver == .postgresql) && self.dataImport?.blocksWrites != true && !self.queryBlocksWrites && !self.newTable.blocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites && self.browser.selectedObject.flatMap { self.schema.drafts[$0.id] }.map { !$0.hasChanges && !$0.requiresReload } != false
        }
        schema.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        schema.isCurrent = { [weak browser] object in browser?.selectedObject?.editingSelection == object.editingSelection && browser?.isBackgrounded == false }
        schema.allowsWrites = { [weak self] in self.map { !$0.externalWriteFence() && ($0.profile.driver == .mysql || $0.profile.driver == .postgresql) && $0.dataImport?.blocksWrites != true && !$0.queryBlocksWrites && !$0.tableActions.blocksWrites && !$0.newTable.blocksWrites } ?? false }
        schema.hasPendingData = { [weak self] object in
            guard let self else { return true }
            return self.queryBlocksWrites || self.browser.changesByObject[object.id]?.hasChanges == true
                || self.queriesHavePendingChanges(for: object)
                || self.browser.changesByObject.values.contains { $0.isSubmitting } || self.queriesHaveSubmittingChanges
        }
        newTable.currentSchema = { [weak browser] in browser?.selectedSchema }
        newTable.isCurrentSchema = { [weak browser] schema in schema == nil || browser?.selectedSchema == schema }
        newTable.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        newTable.isCurrent = { [weak browser] database in
            browser?.selectedDatabase == database && browser?.catalogKind == .table && browser?.isBackgrounded == false
        }
        newTable.allowsWrites = { [weak self] in
            guard let self else { return false }
            return !self.externalWriteFence() && (self.profile.driver == .mysql || self.profile.driver == .postgresql) && self.dataImport?.blocksWrites != true && !self.queryBlocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites
                && !self.browser.changesByObject.values.contains { $0.isSubmitting } && !self.queriesHaveSubmittingChanges
        }
        newTable.didComplete = { [weak self] object in
            guard let self, self.browser.selectedDatabase == object.database, !self.browser.isBackgrounded else {
                return "表已创建，切回目标数据库并使用顶部刷新读取。"
            }
            self.browser.acceptCreatedTable(object)
            self.invalidateQueries(object)
            self.tableDidCreate?(object)
            return await self.browser.refreshAfterTableAction(object: object)
        }
        schema.didRead = { [weak self] object, snapshot in
            guard let self, let options = snapshot.options,
                  let updated = self.browser.acceptTableComment(options.comment, for: object) else { return }
            self.tableMetadataDidChange?(updated)
        }
        schema.didApply = { [weak self] object in
            self?.browser.schemaDidChange(object); self?.invalidateQueries(object)
        }
        tableActions.didBecomeUncertain = { [weak self] object in
            self?.browser.invalidateForUncertainTableAction(object); self?.invalidateQueries(object)
        }
        tableActions.didComplete = { [weak self] object, statement in
            guard let self else { return nil }
            self.browser.acceptTableAction(statement, object: object)
            self.invalidateQueries(object)
            self.tableDidChange?(object, statement)
            let warning = await self.browser.refreshAfterTableAction(object: object)
            self.tableDidChange?(object, statement)
            return warning
        }
        restoreWorkspace()
        documents.forEach { configureQuery($0.query) }
    }

    private func configureQuery(_ documentQuery: MobileQueryModel) {
        documentQuery.allowsDataMutation = { [weak self, weak documentQuery] in
            guard let self, let documentQuery else { return false }
            return !self.externalWriteFence() && !self.hasUnverifiedQueryWrites && (self.profile.driver == .mysql || self.profile.driver == .postgresql) && self.dataImport?.blocksWrites != true && !self.newTable.blocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites && documentQuery.editing.flatMap { self.schema.drafts[$0.object.id] }.map { !$0.hasChanges && !$0.requiresReload } != false
        }
        documentQuery.allowsSQLExecution = { [weak self] in
            guard let self else { return false }
            return self.dataImport?.blocksWrites != true && !self.newTable.blocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites
                && !self.browser.changesByObject.values.contains { $0.hasChanges || $0.isSubmitting || $0.needsVerification }
                && !self.schema.drafts.values.contains { $0.hasChanges || $0.needsVerification } && !self.newTable.hasPendingChanges
        }
        documentQuery.didApplyDataChanges = { [weak self, weak documentQuery] _ in self?.browser.sqlDidWrite(); self?.invalidateOtherQueries(documentQuery) }
        documentQuery.didExecuteWrite = { [weak self, weak documentQuery] in self?.browser.sqlDidWrite(); self?.schema.sqlDidWrite(); self?.invalidateOtherQueries(documentQuery) }
        documentQuery.allowsSQLStatement = { [weak self] kind in
            if kind == .read { return true }
            guard let self, !self.externalWriteFence() else { return false }
            if kind.requiresWriteAccess || kind == .transaction(.commit) { return !self.hasUnverifiedQueryWrites }
            return true
        }
        documentQuery.persistWriteBoundary = { [weak self, weak documentQuery] unresolved in
            guard let self, let document = self.documents.first(where: { $0.query === documentQuery }) else { return false }
            guard self.archiveReadable else { return false }
            let previous = document.durableWriteFence
            if previous == unresolved { return true }
            document.durableWriteFence = unresolved
            guard self.persistWorkspace() else { document.durableWriteFence = previous; return false }
            return true
        }
        documentQuery.didExecute = { [weak self] sql, database, schema in self?.didExecuteQuery?(sql, database, schema) }
        documentQuery.recoverableContentDidChange = { [weak self] in self?.schedulePersistence() }
    }
    private func invalidateOtherQueries(_ except: MobileQueryModel?) {
        documents.filter { $0.query !== except }.forEach { $0.query.tableDidChange() }
    }

    var hasPendingChanges: Bool { browser.hasPendingChanges || queriesHavePendingChanges || tableActions.blocksWrites || schema.hasPendingChanges || newTable.hasPendingChanges || dataImport?.hasPendingChanges == true }

    func openImport(_ object: MobileDatabaseObject) {
        guard profile.driver == .postgresql, object.kind == .table else { return }
        if let dataImport, dataImport.hasPendingChanges { dataImport.showing = true; return }
        let model = MobileDataImportModel(object: object, configuration: configuration, safetyLock: browser.safetyLock)
        model.contextIsCurrent = { [weak self] in
            guard let self else { return false }
            return !self.browser.isBackgrounded && self.browser.selectedDatabase == object.database && self.browser.selectedSchema == object.schemaName
        }
        model.allowsWrites = { [weak self] in
            guard let self else { return false }
            return !self.externalWriteFence() && !self.queryBlocksWrites && !self.queriesHavePendingChanges && !self.newTable.hasPendingChanges
                && !self.tableActions.blocksWrites && !self.schema.hasPendingChanges && !self.browser.changesByObject.values.contains { $0.hasChanges || $0.isSubmitting || $0.needsVerification }
        }
        model.didComplete = { [weak self] in self?.browser.sqlDidWrite(); self?.schema.sqlDidWrite(); self?.invalidateQueries(object) }
        dataImport = model
    }
    func closeImport(discard: Bool = false) {
        guard let dataImport, !dataImport.isRunning else { return }
        dataImport.cancelRead(); dataImport.showing = false
        if discard { self.dataImport = nil }
    }

    func setBackgrounded(_ backgrounded: Bool) {
        dataImport?.background(backgrounded)
        if backgrounded { newTable.cancel(); tableActions.cancel(); schema.cancel() }
        browser.setBackgrounded(backgrounded)
        if backgrounded { persistWorkspace() }
        documents.forEach { $0.query.setBackgrounded(backgrounded) }
    }

    func cancelAll() {
        dataImport?.cancel()
        newTable.cancel(); tableActions.cancel(); schema.cancel()
        browser.safetyLock.enable()
        persistWorkspace()
        documents.forEach { $0.query.cancelSchemaRead(); _ = $0.query.disconnectSQL() }
        browser.cancelAll()
    }

    @discardableResult
    func newDocument() -> MobileSQLDocument? {
        showingDocuments = false
        let model = makeQueryModel()
        model.database = query.database; model.schemaName = query.schemaName; model.sql = ""
        let document = MobileSQLDocument(title: "查询 \(documents.count + 1)", query: model)
        configureQuery(model); documents.append(document); query = model
        persistWorkspace()
        return document
    }

    func selectDocument(_ id: UUID) {
        showingDocuments = false
        guard let document = documents.first(where: { $0.id == id }) else { return }
        query = document.query
        persistWorkspace()
    }

    func renameDocument(_ id: UUID, title: String) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80 else { documentMessage = "文稿名称须为 1～80 个字符。"; return }
        document.title = title
        persistWorkspace()
    }

    func saveDocument(_ id: UUID) {
        guard let document = documents.first(where: { $0.id == id }), archiveReadable else { return }
        let previous = savedQueries
        let oldID = document.savedQueryID, oldSQL = document.persistedSQL, oldDatabase = document.persistedDatabase
        let saved = SavedQuery(id: oldID ?? UUID(), connectionProfileID: profile.id,
            defaultDatabase: document.query.database, name: document.title, sql: document.query.sql,
            createdAt: oldID.flatMap { id in savedQueries.first { $0.id == id }?.createdAt } ?? .now, updatedAt: .now)
        savedQueries.removeAll { $0.id == saved.id }; savedQueries.append(saved)
        document.savedQueryID = saved.id; document.persistedSQL = saved.sql; document.persistedDatabase = saved.defaultDatabase
        if !persistWorkspace() {
            savedQueries = previous; document.savedQueryID = oldID
            document.persistedSQL = oldSQL; document.persistedDatabase = oldDatabase
        }
    }

    func openSavedQuery(_ saved: SavedQuery) {
        if let document = documents.first(where: { $0.savedQueryID == saved.id }) { selectDocument(document.id); return }
        guard let document = newDocument() else { return }
        document.title = saved.name; document.savedQueryID = saved.id
        document.query.database = saved.defaultDatabase ?? profile.database; document.query.sql = saved.sql
        document.persistedSQL = saved.sql; document.persistedDatabase = saved.defaultDatabase
        persistWorkspace()
    }

    func deleteSavedQuery(_ id: UUID) {
        let previous = savedQueries
        savedQueries.removeAll { $0.id == id }
        guard persistWorkspace() else { savedQueries = previous; return }
        for document in documents where document.savedQueryID == id {
            document.savedQueryID = nil; document.persistedSQL = ""; document.persistedDatabase = document.query.database
        }
        persistWorkspace()
    }

    func recoverArchiveAfterBackup() {
        do {
            recoveryBackupURL = try workspaceRepository.backupOriginal(profileID: profile.id)
            archiveReadable = true
            persistWorkspace()
        } catch { documentMessage = "原文件备份失败，尚未覆盖工作区：" + error.localizedDescription }
    }

    @discardableResult
    func closeDocument(_ id: UUID, discarding snapshot: WorkspaceQueryDocumentCloseSnapshot? = nil) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return false }
        let document = documents[index]
        guard !document.query.isLoading, !document.query.isLoadingEditing, !document.query.hasPendingChanges else {
            documentMessage = "请先停止查询、处理数据改动并提交或回滚事务，再关闭文稿。"; return false
        }
        guard !document.isDirty || snapshot == document.closeSnapshot else {
            documentMessage = "文稿有未保存内容，请保存或确认丢弃当前版本。"; return false
        }
        let previous = documents, previousQuery = query
        documents.remove(at: index)
        if documents.isEmpty {
            let replacement = makeQueryModel(); replacement.sql = ""; configureQuery(replacement)
            documents = [.init(title: "查询 1", query: replacement)]
        }
        if query === document.query { query = documents[min(index, documents.count - 1)].query }
        guard persistWorkspace() else { documents = previous; query = previousQuery; return false }
        _ = document.query.disconnectSQL()
        return true
    }

    @discardableResult
    func rollbackAndCloseDocument(_ id: UUID, discarding snapshot: WorkspaceQueryDocumentCloseSnapshot? = nil) async -> Bool {
        guard let document = documents.first(where: { $0.id == id }), !document.query.isLoading else { return false }
        if document.query.transactionState == .inTransaction { await document.query.transaction(.rollback)?.value }
        return closeDocument(id, discarding: snapshot)
    }

    private func restoreWorkspace() {
        restoringWorkspace = true
        defer { restoringWorkspace = false }
        do {
            guard let archive = try workspaceRepository.load(profileID: profile.id) else { return }
            savedQueries = archive.savedQueries
            navigationMode = archive.navigationMode ?? "tables"
            recoveryBackupURL = archive.backupFilename.flatMap { workspaceRepository.backupURL(profileID: profile.id, filename: $0) }
            let restored = archive.documents.map { item in
                let model = makeQueryModel()
                model.database = item.draft.defaultDatabase ?? profile.database; model.schemaName = item.schemaName
                model.sql = item.draft.sql
                let location = min(item.selectionLocation, model.sql.utf16.count)
                model.executionInput.selection = .init(location: location, length: min(item.selectionLength, model.sql.utf16.count - location))
                let document = MobileSQLDocument(id: item.metadata.id, title: item.metadata.title, query: model,
                    saved: savedQueries.first { $0.id == item.metadata.savedQueryID }, createdAt: item.draft.createdAt)
                if item.needsWriteVerification == true { document.durableWriteFence = true; model.restoreUnverifiedOutcome() }
                return document
            }
            if !restored.isEmpty {
                documents = restored
                query = documents.first { $0.id == archive.selectedDocumentID }?.query ?? documents[0].query
            }
            if let state = archive.browser { browser.restore(state) }
            else { browser.restoreDatabaseContext(database: query.database, schema: query.schemaName) }
            documentMessage = "已恢复文稿；结果和事务不恢复，请按需执行查询。"
        } catch { archiveReadable = false; documentMessage = error.localizedDescription }
    }

    private func schedulePersistence() {
        guard !restoringWorkspace else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation() }
            catch { return }
            self?.persistWorkspace()
        }
    }

    @discardableResult
    func persistWorkspace() -> Bool {
        persistenceTask?.cancel(); persistenceTask = nil
        guard archiveReadable, !restoringWorkspace else { return false }
        let now = Date.now
        let state = MobileWorkspaceArchive(profileID: profile.id, selectedDocumentID: activeDocument?.id,
            documents: documents.map { document in
                let model = document.query, range = model.executionInput.selection
                return .init(metadata: .init(id: document.id, title: document.title, savedQueryID: document.savedQueryID,
                    defaultDatabase: model.database), draft: .init(id: document.id, workspaceID: id,
                        connectionProfileID: profile.id, defaultDatabase: model.database, sql: model.sql,
                        createdAt: document.createdAt, updatedAt: now), schemaName: model.schemaName,
                    selectionLocation: range.location == NSNotFound ? 0 : max(0, range.location), selectionLength: max(0, range.length), needsWriteVerification: document.durableWriteFence || model.writeOutcomeUncertain)
            }, savedQueries: savedQueries, browser: browser.restoration, navigationMode: navigationMode, backupFilename: recoveryBackupURL?.lastPathComponent)
        do { try workspaceRepository.write(state); documentMessage = nil; return true }
        catch { documentMessage = "文稿尚未保存到磁盘：" + error.localizedDescription; return false }
    }
}
