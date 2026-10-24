import Foundation
import Observation

@MainActor @Observable
final class MobileDatabaseWorkspace: Identifiable {
    let id = UUID()
    let profile: MobileConnectionProfile
    private let configuration: MobileSQLConfiguration
    let query: MobileQueryModel
    let browser: MobileBrowserModel
    let schema: MobileSchemaController
    let tableActions: MobileTableActionController
    let newTable: MobileNewTableController
    var dataImport: MobileDataImportModel?
    @ObservationIgnored var tableMetadataDidChange: ((MobileDatabaseObject) -> Void)?
    @ObservationIgnored var tableDidCreate: ((MobileDatabaseObject) -> Void)?
    @ObservationIgnored var tableDidChange: ((MobileDatabaseObject, WorkspaceTableActionStatement) -> Void)?

    init(profile: MobileConnectionProfile, password: String?, service: any MobileSQLServicing, tableActionService: any MobileTableActionServicing = MobileTableActionService(), queryExecutor: any MobileQueryExecuting = MobileMariaDBExecutor(), schemaService: any MobileSchemaServicing = MobileSchemaService(), newTableService: any MobileNewTableServicing = MobileNewTableService()) {
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
        query = MobileQueryModel(executor: queryExecutor, metadataService: service, mutationService: mutations, safetyLock: browser.safetyLock)
        query.driver = profile.driver
        query.schemaName = profile.schemaName
        query.exportDialect = profile.driver == .postgresql ? .postgresql : profile.driver == .doris ? .doris : .mysql
        query.host = profile.host
        query.port = String(profile.port)
        query.username = profile.username
        query.password = password ?? ""
        query.database = profile.database
        query.tlsMode = profile.tlsMode
        if profile.driver == .postgresql { tableActions.onImport = { [weak self] object in self?.openImport(object) } }
        browser.allowsDatabaseChange = { [weak query] in query?.hasPendingChanges == false }
        tableActions.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        tableActions.isCurrent = { [weak browser] draft in
            browser?.selectedDatabase == draft.object.database && browser?.contextID == draft.contextID && browser?.isBackgrounded == false
        }
        tableActions.hasPendingChanges = { [weak self] object in
            guard let self else { return true }
            let table = self.browser.changesByObject[object.id]
            return self.dataImport?.blocksWrites == true || self.query.blocksOtherWrites || self.newTable.blocksWrites || self.schema.drafts[object.id]?.hasChanges == true || self.schema.blocksWrites || table?.hasChanges == true || self.query.hasPendingChanges(for: object)
                || self.browser.changesByObject.values.contains { $0.isSubmitting } || self.query.hasSubmittingChanges
        }
        browser.allowsDataMutation = { [weak self] in
            guard let self else { return false }
            return (self.profile.driver == .mysql || self.profile.driver == .postgresql) && self.dataImport?.blocksWrites != true && !self.query.blocksOtherWrites && !self.newTable.blocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites && self.browser.selectedObject.flatMap { self.schema.drafts[$0.id] }.map { !$0.hasChanges && !$0.requiresReload } != false
        }
        query.allowsDataMutation = { [weak self] in
            guard let self else { return false }
            return (self.profile.driver == .mysql || self.profile.driver == .postgresql) && self.dataImport?.blocksWrites != true && !self.newTable.blocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites && self.query.editing.flatMap { self.schema.drafts[$0.object.id] }.map { !$0.hasChanges && !$0.requiresReload } != false
        }
        query.allowsSQLExecution = { [weak self] in
            guard let self else { return false }
            return self.dataImport?.blocksWrites != true && !self.newTable.blocksWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites
                && !self.browser.changesByObject.values.contains { $0.hasChanges || $0.isSubmitting || $0.needsVerification }
                && !self.schema.drafts.values.contains { $0.hasChanges || $0.needsVerification } && !self.newTable.hasPendingChanges
        }
        query.didApplyDataChanges = { [weak self] _ in self?.browser.sqlDidWrite() }
        query.didExecuteWrite = { [weak self] in self?.browser.sqlDidWrite(); self?.schema.sqlDidWrite() }
        schema.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        schema.isCurrent = { [weak browser] object in browser?.selectedObject?.editingSelection == object.editingSelection && browser?.isBackgrounded == false }
        schema.allowsWrites = { [weak self] in self.map { ($0.profile.driver == .mysql || $0.profile.driver == .postgresql) && $0.dataImport?.blocksWrites != true && !$0.query.blocksOtherWrites && !$0.tableActions.blocksWrites && !$0.newTable.blocksWrites } ?? false }
        schema.hasPendingData = { [weak self] object in
            guard let self else { return true }
            return self.query.blocksOtherWrites || self.browser.changesByObject[object.id]?.hasChanges == true
                || self.query.hasPendingChanges(for: object)
                || self.browser.changesByObject.values.contains { $0.isSubmitting } || self.query.hasSubmittingChanges
        }
        newTable.currentSchema = { [weak browser] in browser?.selectedSchema }
        newTable.isCurrentSchema = { [weak browser] schema in schema == nil || browser?.selectedSchema == schema }
        newTable.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        newTable.isCurrent = { [weak browser] database in
            browser?.selectedDatabase == database && browser?.catalogKind == .table && browser?.isBackgrounded == false
        }
        newTable.allowsWrites = { [weak self] in
            guard let self else { return false }
            return (self.profile.driver == .mysql || self.profile.driver == .postgresql) && self.dataImport?.blocksWrites != true && !self.query.blocksOtherWrites && !self.tableActions.blocksWrites && !self.schema.blocksWrites
                && !self.browser.changesByObject.values.contains { $0.isSubmitting } && !self.query.hasSubmittingChanges
        }
        newTable.didComplete = { [weak self] object in
            guard let self, self.browser.selectedDatabase == object.database, !self.browser.isBackgrounded else {
                return "表已创建，切回目标数据库并使用顶部刷新读取。"
            }
            self.browser.acceptCreatedTable(object)
            self.query.tableDidChange(object)
            self.tableDidCreate?(object)
            return await self.browser.refreshAfterTableAction(object: object)
        }
        schema.didRead = { [weak self] object, snapshot in
            guard let self, let options = snapshot.options,
                  let updated = self.browser.acceptTableComment(options.comment, for: object) else { return }
            self.tableMetadataDidChange?(updated)
        }
        schema.didApply = { [weak self] object in
            self?.browser.schemaDidChange(object); self?.query.tableDidChange(object)
        }
        tableActions.didBecomeUncertain = { [weak self] object in
            self?.browser.invalidateForUncertainTableAction(object); self?.query.tableDidChange(object)
        }
        tableActions.didComplete = { [weak self] object, statement in
            guard let self else { return nil }
            self.browser.acceptTableAction(statement, object: object)
            self.query.tableDidChange(object)
            self.tableDidChange?(object, statement)
            let warning = await self.browser.refreshAfterTableAction(object: object)
            self.tableDidChange?(object, statement)
            return warning
        }
    }

    var hasPendingChanges: Bool { browser.hasPendingChanges || query.hasPendingChanges || tableActions.blocksWrites || schema.hasPendingChanges || newTable.hasPendingChanges || dataImport?.hasPendingChanges == true }

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
            return !self.query.blocksOtherWrites && !self.query.hasPendingChanges && !self.newTable.hasPendingChanges
                && !self.tableActions.blocksWrites && !self.schema.hasPendingChanges && !self.browser.changesByObject.values.contains { $0.hasChanges || $0.isSubmitting || $0.needsVerification }
        }
        model.didComplete = { [weak self] in self?.browser.sqlDidWrite(); self?.schema.sqlDidWrite(); self?.query.tableDidChange(object) }
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
        query.setBackgrounded(backgrounded)
    }

    func cancelAll() {
        dataImport?.cancel()
        newTable.cancel(); tableActions.cancel(); schema.cancel()
        browser.safetyLock.enable()
        _ = query.disconnectSQL()
        browser.cancelAll()
    }
}
