import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileSchemaStateTests {
    func fixture(service: SchemaStateService = .init()) -> (MobileSchemaController, MobileDatabaseObject) {
        let controller = MobileSchemaController(configuration: .init(host: "fake", port: 1, username: "fake", password: "", database: "db", tlsMode: .disabled), safetyLock: .init(), service: service)
        let context = UUID(); controller.contextID = { context }; controller.isCurrent = { _ in true }; controller.hasPendingData = { _ in false }; controller.allowsWrites = { true }
        return (controller,.init(database: "db", name: "t", kind: .table, comment: ""))
    }
    func stage(_ draft: MobileSchemaDraft) throws {
        let column = try #require(draft.state.columns.first { $0.definition.name == "title" }); var definition = column.definition
        definition.comment = "changed"; draft.updateColumn(column.id, definition: definition, primary: false)
    }
    @Test func bothPresentationsAndSectionsKeepSameDraftIDsAndSQLWithStagedDeleteUndo() async throws {
        let (controller, object) = fixture(); await controller.load(object)?.value
        let draft = controller.draft(for: object), ids = draft.state.columns.map(\.id)
        try stage(draft); let plan = draft.plan
        draft.presentation = .list; draft.section = .indexes; draft.section = .columns; draft.presentation = .table
        #expect(draft.plan == plan); #expect(draft.state.columns.map(\.id) == ids); #expect(draft.hasChanges)
        let content = MobileSchemaContent(controller: controller, draft: draft), data = content.gridData
        #expect(data.rows[1].last == "changed"); #expect(!data.pendingCells.isEmpty)
        draft.delete(ids[1]); #expect(draft.state.columns[1].isDeleted); draft.restore(ids[1]); #expect(!draft.state.columns[1].isDeleted)
        draft.discard(); #expect(!draft.hasChanges); #expect(draft.plan.statements.isEmpty)
    }
    @Test func sharedColumnRenameUpdatesIndexReferenceAndPrimaryKeySemantics() async throws {
        let (controller, object) = fixture(); await controller.load(object)?.value; let draft = controller.draft(for: object)
        let title = try #require(draft.state.columns.first { $0.definition.name == "title" }); var d = title.definition; d.name = "renamed"
        draft.updateColumn(title.id, definition: d, primary: false)
        #expect(draft.state.indexes.first { $0.definition.name == "title_idx" }?.definition.columns.first?.name == "renamed")
        #expect(draft.plan.statements.first?.sql.contains("DROP INDEX") == true)
        #expect(draft.plan.statements.contains { $0.sql.contains("CHANGE COLUMN `title` `renamed`") })
    }
    @Test func pendingLockViewAndChangedContextRefuseSubmissionAndKeepDraft() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let draft = controller.draft(for: object); try stage(draft)
        #expect(controller.submit(draft) == nil)
        controller.safetyLock.disable(); controller.hasPendingData = { _ in true }; #expect(controller.submit(draft) == nil)
        controller.hasPendingData = { _ in false }; controller.isCurrent = { _ in false }; #expect(controller.submit(draft) == nil)
        #expect(draft.hasChanges); #expect(await service.applies == 0)
        controller.isCurrent = { _ in true }
        let view = MobileDatabaseObject(database: "db", name: "view", kind: .view, comment: "")
        await controller.load(view)?.value; #expect(!controller.canEdit(controller.draft(for: view)))
    }
    @Test func failedReadKeepsSnapshotAndUnsubmittedDraftRefreshDoesNotReplaceIt() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let draft = controller.draft(for: object), epoch = draft.epoch, snapshot = draft.snapshot
        await service.setReadFailure(true); await controller.load(object)?.value
        #expect(draft.snapshot == snapshot); #expect(draft.epoch == epoch); #expect(draft.message != nil); #expect(draft.isError)
        try stage(draft); #expect(controller.load(object) == nil); #expect(draft.hasChanges); #expect(draft.epoch == epoch)
        draft.discard(); #expect(!draft.isError)
        await service.setReadFailure(false); await controller.load(object)?.value
        #expect(!draft.isError); #expect(draft.message == nil); #expect(draft.snapshot == snapshot)
    }
    @Test func sqlWriteInvalidationRejectsAnOlderInflightMetadataReply() async throws {
        let service = SchemaStateService(), (controller, object) = fixture(service: service)
        await controller.load(object)?.value
        let draft = controller.draft(for: object), prior = draft.snapshot
        await service.setGate(true)
        let read = controller.load(object)
        await service.waitForGate()
        controller.sqlDidWrite()
        #expect(!controller.isLoading); #expect(draft.requiresReload)
        await service.releaseGate(); await read?.value
        #expect(draft.snapshot == prior); #expect(draft.requiresReload)
        #expect(!controller.canEdit(draft))
    }

    @Test func lateCancelledReadCannotReplaceNewObjectOrPriorSnapshot() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let original = controller.draft(for: object).snapshot
        await service.setGate(true)
        let first = controller.load(object)
        await service.waitForGate()
        controller.cancelRead(); controller.isCurrent = { _ in false }; await service.releaseGate(); await first?.value
        #expect(!controller.isLoading); #expect(controller.draft(for: object).snapshot == original)
    }
    @Test func partialOutcomeBlocksAllWritesAndSurvivesViewSwitchUntilExplicitReconcile() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let draft = controller.draft(for: object); try stage(draft)
        await service.setPartial(true); controller.safetyLock.disable(); await controller.submit(draft)?.value
        #expect(draft.needsVerification); #expect(controller.blocksWrites); #expect(controller.safetyLock.isEnabled)
        draft.presentation = .list; draft.presentation = .table; controller.safetyLock.disable()
        #expect(controller.submit(draft) == nil); #expect(controller.load(object) == nil); #expect(await service.applies == 1)
        await controller.load(object, reconcile: true)?.value
        #expect(!controller.blocksWrites); #expect(!draft.hasChanges); #expect(!draft.needsVerification)
    }
    @Test func confirmedWriteFollowedByReadFailureNeverBecomesRetryable() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let draft = controller.draft(for: object); try stage(draft)
        await service.setFailAfterApply(true); controller.safetyLock.disable(); await controller.submit(draft)?.value
        #expect(draft.requiresReload); #expect(draft.isError); #expect(controller.submit(draft) == nil); #expect(await service.applies == 1)
        await service.setReadFailure(false); await controller.load(object)?.value
        #expect(!draft.requiresReload); #expect(!draft.hasChanges); #expect(await service.applies == 1)
    }
    @Test func backgroundCancellationRetainsDraftAndAcknowledgedSuccessRequiresReload() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let draft = controller.draft(for: object); try stage(draft)
        await service.setWriteGate(true); controller.safetyLock.disable()
        let operation = controller.submit(draft); await service.waitForGate()
        controller.cancel(); controller.isCurrent = { _ in false }; await service.releaseGate(); await operation?.value
        #expect(draft.hasChanges); #expect(!draft.needsVerification); #expect(await service.writes == 0); #expect(controller.safetyLock.isEnabled)
        controller.isCurrent = { _ in true }; controller.safetyLock.disable()
        controller.didApply = { _ in controller.isCurrent = { _ in false } }
        await controller.submit(draft)?.value
        #expect(draft.requiresReload); #expect(!draft.needsVerification); #expect(await service.writes == 1)
    }
    @Test func contextAwayAndBackBeforeAuthorizeStillRejectsCapturedPlan() async throws {
        let service = SchemaStateService(); let (controller, object) = fixture(service: service)
        await controller.load(object)?.value; let draft = controller.draft(for: object); try stage(draft)
        var context = UUID(); controller.contextID = { context }; controller.safetyLock.disable()
        await service.setWriteGate(true); let operation = controller.submit(draft); await service.waitForGate()
        context = UUID(); await service.releaseGate(); await operation?.value
        #expect(await service.writes == 0); #expect(draft.hasChanges); #expect(!draft.needsVerification)
    }
}

actor SchemaStateService: MobileSchemaServicing {
    var options: WorkspaceDatabaseTableOptions?
    func setOptions(_ value: WorkspaceDatabaseTableOptions?) { options = value }
    var applies = 0, writes = 0
    var readFailure = false, partial = false, failAfterApply = false, gate = false, writeGate = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func setReadFailure(_ value: Bool) { readFailure = value }
    func setPartial(_ value: Bool) { partial = value }
    func setFailAfterApply(_ value: Bool) { failAfterApply = value }
    func setGate(_ value: Bool) { gate = value }
    func setWriteGate(_ value: Bool) { writeGate = value }
    func waitForGate() async { if continuation != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func releaseGate() { continuation?.resume(); continuation = nil; gate = false; writeGate = false }
    private func suspend() async { await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil } }
    func load(object: MobileDatabaseObject, configuration: MobileSQLConfiguration) async throws -> MobileSchemaSnapshot {
        if gate { await suspend() }
        if readFailure { throw URLError(.notConnectedToInternet) }
        var snapshot = Self.snapshot; snapshot.options = options; return snapshot
    }
    func apply(object: MobileDatabaseObject, baseline: MobileSchemaSnapshot, plan: WorkspaceDatabaseSchemaExecutionPlan, configuration: MobileSQLConfiguration, authorize: @escaping @Sendable () async throws -> Void) async throws {
        applies += 1; if writeGate { await suspend() }; try await authorize(); writes += 1
        if partial { throw MobileSchemaError.partial(completed: 1, total: 2, detail: "lost acknowledgement") }
        if case .changes(let changes) = plan.source, let change = changes.tableOptionsChange { options = change.updated }
        if failAfterApply { readFailure = true }
    }
    static var snapshot: MobileSchemaSnapshot {
        .init(columns: [
            .init(name: "id", type: "int", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: ""),
            .init(name: "title", type: "varchar(80)", collation: "utf8mb4_0900_ai_ci", isNullable: true, key: "MUL", defaultValue: nil, extra: "", comment: "")
        ], indexes: [
            .init(name: "PRIMARY", columns: [.init(sequence: 1, name: "id", prefixLength: nil, direction: "A", isExpression: false)], isUnique: true, type: "BTREE", cardinality: nil, isVisible: true, comment: ""),
            .init(name: "title_idx", columns: [.init(sequence: 1, name: "title", prefixLength: nil, direction: "A", isExpression: false)], isUnique: false, type: "BTREE", cardinality: nil, isVisible: true, comment: "")
        ], choices: .empty, ddl: "owned fake schema")
    }
}
