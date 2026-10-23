import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileNewTableTests {
    func fixture(_ service: NewTableFixture = .init()) throws -> (MobileNewTableController, MobileNewTableDraft) {
        let c = MobileNewTableController(configuration: .init(host: "fake", port: 1, username: "fake", password: "", database: "db", tlsMode: .disabled), safetyLock: .init(), service: service)
        let context = UUID(); c.contextID = { context }; c.isCurrent = { $0 == "db" }; c.allowsWrites = { true }
        c.present(database: "db"); let d = try #require(c.request)
        d.definition.tableName = "new_table"
        let column = try #require(d.definition.editor.columns.first)
        var def = column.definition; def.name = "id"; def.type = "BIGINT"; def.isAutoIncrement = true
        c.editingContext(d).updateColumn(column.id, def, true)
        return (c,d)
    }
    @Test func sharedMacDraftDefaultsResetTypeSemanticsAndIndexReferencesStayAligned() throws {
        let (c,d) = try fixture(), shared = d.definition
        #expect(shared.editor.columns.count == 1); #expect(shared.editor.isPrimaryKey(columnID: shared.editor.columns[0].id))
        #expect(!shared.editor.columns[0].definition.isNullable); #expect(shared.editor.columns[0].definition.defaultMode == .none)
        let id = shared.editor.addColumn(); var column = try #require(shared.editor.columns.first { $0.id == id }).definition
        column.name = "title"; c.editingContext(d).updateColumn(id, column, false)
        let index = shared.editor.addIndex(); var idx = try #require(shared.editor.indexes.first { $0.id == index }).definition
        idx.name = "title_idx"; idx.columns = [.init(name: "title", sourceColumnID: id)]; shared.editor.updateIndex(id: index, definition: idx)
        column.name = "renamed"; c.editingContext(d).updateColumn(id, column, false)
        #expect(shared.editor.indexes.first { $0.id == index }?.definition.columns.first?.name == "renamed")
        shared.editor.updateSchemaChoices(.init(engines: ["InnoDB"], characterSets: ["utf8mb4"], collations: []))
        shared.reset(); #expect(shared.editor.schemaChoices.engines == ["InnoDB"])
        #expect(shared.editor.columns.count == 1); #expect(shared.editor.columns[0].definition.type == "VARCHAR(255)")
        #expect(shared.tableName.isEmpty); #expect(!d.isValid)
    }
    @Test func lockedInvalidChangedPreviewAndOtherWritesNeverSubmitAndDismissPreservesDefinition() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s), plan = d.plan
        #expect(c.submit(d, plan: plan) == nil)
        c.dismiss(); c.present(database: "db"); #expect(c.request === d)
        c.safetyLock.disable(); c.allowsWrites = { false }; #expect(c.submit(d, plan: plan) == nil)
        c.allowsWrites = { true }; d.definition.tableName = "changed"; #expect(c.submit(d, plan: plan) == nil)
        d.definition.tableName = " "; #expect(c.submit(d, plan: d.plan) == nil)
        #expect(await s.calls == 0); #expect(c.hasPendingChanges)
        c.discard(d); #expect(!c.hasPendingChanges)
    }
    @Test func choicesFailureRetryAndSlowStaleLoadKeepDefinitionAndFinishLoading() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s), plan = d.plan
        await s.setMode(.readFailure); await c.loadChoices(d)?.value
        #expect(d.choicesError != nil); #expect(d.plan == plan); #expect(!c.isLoadingChoices)
        await s.setMode(.normal); await c.loadChoices(d)?.value
        #expect(d.choicesError == nil); #expect(d.definition.editor.schemaChoices.engines == ["InnoDB"]); #expect(d.plan == plan)
        await s.setMode(.holdChoices); let task = c.loadChoices(d); await s.waitForGate()
        c.contextID = { UUID() }; await s.release(); await task?.value
        #expect(!c.isLoadingChoices); #expect(d.plan == plan)
    }
    @Test func expiredChoicesCannotReplaceReopenedNewDraft() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s)
        await s.setMode(.holdChoices); let task = c.loadChoices(d); await s.waitForGate()
        c.discard(d); c.present(database: "db"); let next = try #require(c.request)
        await s.release(); await task?.value
        #expect(next !== d); #expect(next.definition.editor.schemaChoices == .empty); #expect(!c.isLoadingChoices)
    }
    @Test func repeatedSubmissionAndDismissStayBlockedUntilAckThenRefreshFailureCannotReplay() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s); c.safetyLock.disable()
        await s.setMode(.holdAcknowledged); c.didComplete = { _ in "表已创建，但目录刷新失败" }
        let task = try #require(c.submit(d, plan: d.plan)); await s.waitForGate()
        #expect(c.submit(d, plan: d.plan) == nil); c.dismiss(); #expect(c.request === d)
        await s.release(); await task.value
        #expect(d.hasCompleted); #expect(!d.needsVerification); #expect(d.message?.contains("刷新失败") == true)
        #expect(c.submit(d, plan: d.plan) == nil); #expect(await s.sent == 1)
        c.dismiss(); #expect(c.draft == nil); #expect(!c.hasPendingChanges)
    }
    @Test func knownServerRejectionCanBeEditedAndRetriedWithoutDiscardingDefinition() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s); c.safetyLock.disable(); await s.setMode(.reject)
        await c.submit(d, plan: d.plan)?.value
        #expect(!d.hasCompleted); #expect(!d.needsVerification); #expect(c.canEdit(d)); #expect(d.message != nil)
        await s.setMode(.normal); d.definition.tableName = "fixed"; await c.submit(d, plan: d.plan)?.value
        #expect(d.hasCompleted); #expect(await s.calls == 2); #expect(c.request == nil)
    }
    @Test func unknownAckSurvivesDismissAndBlocksAllWritesUntilExplicitAcknowledgement() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s); c.safetyLock.disable(); await s.setMode(.unknown)
        await c.submit(d, plan: d.plan)?.value
        #expect(d.needsVerification); #expect(c.safetyLock.isEnabled); #expect(c.blocksWrites)
        c.dismiss(); c.present(database: "db"); #expect(c.request === d)
        c.safetyLock.disable(); #expect(c.submit(d, plan: d.plan) == nil); c.discard(d); #expect(c.draft === d)
        c.acknowledgeVerification(d); #expect(!c.blocksWrites); #expect(c.safetyLock.isEnabled); #expect(await s.sent == 1)
    }
    @Test(arguments: [false,true]) func backgroundOrChangedContextBeforeSendPreservesDraftAndNeverExecutes(background: Bool) async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s); c.safetyLock.disable(); await s.setMode(.holdBeforeSend)
        let task = try #require(c.submit(d, plan: d.plan)); await s.waitForGate()
        if background { c.cancel() } else { let changed = UUID(); c.contextID = { changed } }
        await s.release(); await task.value
        #expect(!d.hasCompleted); #expect(!d.needsVerification); #expect(await s.sent == 0); #expect(c.hasPendingChanges)
    }
    @Test func successAcknowledgedAfterBackgroundDoesNotNavigateOrBecomeRetryable() async throws {
        let s = NewTableFixture(), (c,d) = try fixture(s); c.safetyLock.disable(); await s.setMode(.holdAcknowledged)
        var navigated = false; c.didComplete = { _ in navigated = true; return nil }
        let task = try #require(c.submit(d, plan: d.plan)); await s.waitForGate(); c.cancel(); c.isCurrent = { _ in false }
        await s.release(); await task.value
        #expect(d.hasCompleted); #expect(!d.needsVerification); #expect(!navigated); #expect(c.submit(d, plan: d.plan) == nil)
    }
    @Test func workspacePendingProfileGuardAndUnknownFenceAlsoBlockRowAndSchemaWrites() async throws {
        let service = NewTableFixture(), profile = MobileConnectionProfile(id: UUID(), name: "owned", host: "fake", port: 1, username: "fake", database: "db", tlsMode: .disabled, remembersPassword: false, requiresPassword: false)
        let workspace = MobileDatabaseWorkspace(profile: profile, password: nil, service: ActionFixture(), newTableService: service)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        let c = workspace.newTable; c.present(database: "db"); let d = try #require(c.request)
        #expect(workspace.hasPendingChanges)
        d.definition.tableName = "t_new"; let item = try #require(d.definition.editor.columns.first); var def = item.definition; def.name = "id"
        c.editingContext(d).updateColumn(item.id, def, false); c.safetyLock.disable(); await service.setMode(.unknown)
        await c.submit(d, plan: d.plan)?.value
        #expect(c.blocksWrites); #expect(!workspace.browser.allowsDataMutation()); #expect(!workspace.query.allowsDataMutation()); #expect(!workspace.schema.allowsWrites())
        workspace.cancelAll()
    }
}

actor NewTableFixture: MobileNewTableServicing {
    enum Mode { case normal, readFailure, holdChoices, holdBeforeSend, holdAcknowledged, reject, unknown }
    var mode = Mode.normal
    private(set) var calls = 0, sent = 0
    private var gate: CheckedContinuation<Void,Never>?, waiting: CheckedContinuation<Void,Never>?
    func setMode(_ value: Mode) { mode = value }
    func waitForGate() async { if gate != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func release() { gate?.resume(); gate = nil; mode = .normal }
    private func suspend() async { await withCheckedContinuation { gate = $0; waiting?.resume(); waiting = nil } }
    func choices(configuration: MariaDBTransportConfiguration) async throws -> WorkspaceDatabaseSchemaChoices {
        if mode == .holdChoices { await suspend() }
        if mode == .readFailure { throw URLError(.notConnectedToInternet) }
        return .init(engines: ["InnoDB"], characterSets: ["utf8mb4"], collations: [])
    }
    func create(plan: WorkspaceDatabaseSchemaExecutionPlan, configuration: MariaDBTransportConfiguration, authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceDatabaseObjectSelection {
        calls += 1
        if mode == .holdBeforeSend { await suspend() }
        try Task.checkCancellation(); try await authorize()
        if mode == .reject { throw MobileNewTableError.invalidDefinition }
        sent += 1
        if mode == .holdAcknowledged { await suspend() }
        if mode == .unknown { throw MobileNewTableError.outcomeUnknown("ack lost") }
        guard case .tableMutation(let mutation) = plan.source, let selection = mutation.resultingSelection else { throw MobileNewTableError.invalidDefinition }
        return selection
    }
}
