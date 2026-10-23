import Foundation
import Observation

@MainActor @Observable
final class MobileDatabaseWorkspace: Identifiable {
    let id = UUID()
    let profile: MobileConnectionProfile
    let query: MobileQueryModel
    let browser: MobileBrowserModel
    let schema: MobileSchemaController
    let tableActions: MobileTableActionController
    @ObservationIgnored var tableDidChange: ((MobileDatabaseObject, WorkspaceTableActionStatement) -> Void)?

    init(profile: MobileConnectionProfile, password: String?, service: any MobileMySQLServicing, tableActionService: any MobileTableActionServicing = MobileTableActionService(), queryExecutor: any MobileQueryExecuting = MobileMariaDBExecutor(), schemaService: any MobileSchemaServicing = MobileSchemaService()) {
        self.profile = profile
        browser = MobileBrowserModel(configuration: profile.configuration(password: password), service: service)
        tableActions = MobileTableActionController(configuration: profile.configuration(password: password), safetyLock: browser.safetyLock, service: tableActionService)
        schema = MobileSchemaController(configuration: profile.configuration(password: password), safetyLock: browser.safetyLock, service: schemaService)
        browser.schema = schema
        query = MobileQueryModel(executor: queryExecutor, metadataService: service, safetyLock: browser.safetyLock)
        query.host = profile.host
        query.port = String(profile.port)
        query.username = profile.username
        query.password = password ?? ""
        query.database = profile.database
        query.tlsMode = profile.tlsMode
        tableActions.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        tableActions.isCurrent = { [weak browser] draft in
            browser?.selectedDatabase == draft.object.database && browser?.contextID == draft.contextID && browser?.isBackgrounded == false
        }
        tableActions.hasPendingChanges = { [weak self] object in
            guard let self else { return true }
            let table = self.browser.changesByObject[object.id]
            return self.schema.drafts[object.id]?.hasChanges == true || self.schema.blocksWrites || table?.hasChanges == true || self.query.editing?.object.editingSelection == object.editingSelection && self.query.hasPendingChanges
                || self.browser.changesByObject.values.contains { $0.isSubmitting } || self.query.editing?.isSubmitting == true
        }
        browser.allowsDataMutation = { [weak self] in
            guard let self else { return false }
            return !self.tableActions.blocksWrites && !self.schema.blocksWrites && self.browser.selectedObject.flatMap { self.schema.drafts[$0.id] }.map { !$0.hasChanges && !$0.requiresReload } != false
        }
        query.allowsDataMutation = { [weak self] in
            guard let self else { return false }
            return !self.tableActions.blocksWrites && !self.schema.blocksWrites && self.query.editing.flatMap { self.schema.drafts[$0.object.id] }.map { !$0.hasChanges && !$0.requiresReload } != false
        }
        schema.contextID = { [weak browser] in browser?.contextID ?? UUID() }
        schema.isCurrent = { [weak browser] object in browser?.selectedObject?.editingSelection == object.editingSelection && browser?.isBackgrounded == false }
        schema.allowsWrites = { [weak tableActions] in tableActions?.blocksWrites == false }
        schema.hasPendingData = { [weak self] object in
            guard let self else { return true }
            return self.browser.changesByObject[object.id]?.hasChanges == true
                || self.query.editing?.object.editingSelection == object.editingSelection && self.query.hasPendingChanges
                || self.browser.changesByObject.values.contains { $0.isSubmitting } || self.query.editing?.isSubmitting == true
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

    var hasPendingChanges: Bool { browser.hasPendingChanges || query.hasPendingChanges || tableActions.blocksWrites || schema.hasPendingChanges }

    func setBackgrounded(_ backgrounded: Bool) {
        if backgrounded { tableActions.cancel(); schema.cancel() }
        browser.setBackgrounded(backgrounded)
        query.setBackgrounded(backgrounded)
    }

    func cancelAll() {
        tableActions.cancel(); schema.cancel()
        browser.safetyLock.enable()
        if query.isLoading || query.isLoadingEditing { query.cancel() }
        browser.cancelAll()
    }
}
