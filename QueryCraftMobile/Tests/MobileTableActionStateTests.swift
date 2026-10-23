import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileTableActionStateTests {
    func workspace(service: ActionFixture = ActionFixture(), writer: ActionWriter = ActionWriter()) async -> MobileDatabaseWorkspace {
        let profile = MobileConnectionProfile(id: UUID(), name: "owned", host: "127.0.0.1", port: 1, username: "unused",
            database: "db", tlsMode: .disabled, remembersPassword: false, requiresPassword: false)
        let workspace = MobileDatabaseWorkspace(profile: profile, password: nil, service: service,
            tableActionService: writer, queryExecutor: QueryEditingExecutor())
        await writer.bind(service)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        return workspace
    }
    private let object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "comment")

    @Test(arguments: WorkspaceTableAction.allCases)
    func allSixRequireConfirmationLockAndOneCapturedSubmission(_ action: WorkspaceTableAction) async throws {
        let writer = ActionWriter(), workspace = await workspace(writer: writer), controller = workspace.tableActions
        controller.prepare(action, object: object)
        let draft = try #require(controller.request)
        if action == .rename { draft.input = "new`名" }
        if action.isDestructive { #expect(controller.submit(draft) == nil); draft.confirmation = object.name }
        #expect(controller.submit(draft) == nil); #expect(await writer.calls == 0)
        workspace.browser.safetyLock.disable()
        await controller.submit(draft)?.value
        #expect(draft.hasCompleted); #expect(!draft.needsVerification); #expect(await writer.calls == 1)
        #expect(controller.submit(draft) == nil)
        if action == .drop { #expect(workspace.browser.catalog?.objects.contains { $0.name == "t" } == false) }
    }

    @Test func pendingTableAndQueryChangesBlockTargetButUnrelatedDraftsSurviveOtherTableAction() async throws {
        let writer = ActionWriter(), workspace = await workspace(writer: writer), browser = workspace.browser, controller = workspace.tableActions
        await browser.selectObject(object)?.value
        let changes = try #require(browser.currentChanges), page = try #require(browser.snapshot)
        try changes.stage(changes.request(page: page, row: 0, column: 1), text: "table draft", mode: .value)
        controller.prepare(.truncate, object: object)
        let first = try #require(controller.request); first.confirmation = object.name
        browser.safetyLock.disable()
        #expect(controller.submit(first) == nil); #expect(first.message == WorkspaceTableActionError.pendingChanges.localizedDescription)
        changes.discard(); controller.dismiss()
        workspace.query.sql = "SELECT id,name FROM t"; await workspace.query.execute()?.value
        let queryChanges = try #require(workspace.query.editing), queryPage = try #require(workspace.query.editingPage)
        try queryChanges.stage(queryChanges.request(page: queryPage, row: 0, column: 1), text: "query draft", mode: .value)
        controller.prepare(.drop, object: object)
        let target = try #require(controller.request); target.confirmation = object.name
        #expect(controller.submit(target) == nil); #expect(await writer.calls == 0)
        controller.dismiss()
        let other = MobileDatabaseObject(database: "db", name: "other", kind: .table, comment: "")
        controller.prepare(.clear, object: other)
        let unrelated = try #require(controller.request); unrelated.confirmation = other.name
        await controller.submit(unrelated)?.value
        #expect(unrelated.hasCompleted); #expect(queryChanges.hasChanges)
        #expect(!workspace.query.requiresResultReload); #expect(!queryChanges.requiresReload); #expect(queryChanges.canSubmit)
    }

    @Test func contextChangedAwayAndBackCannotUseOldConfirmation() async throws {
        let writer = ActionWriter(), workspace = await workspace(writer: writer), controller = workspace.tableActions
        controller.prepare(.clear, object: object)
        let draft = try #require(controller.request); draft.confirmation = object.name
        workspace.browser.selectDatabase("elsewhere"); workspace.browser.selectDatabase("db")
        workspace.browser.safetyLock.disable()
        #expect(controller.submit(draft) == nil); #expect(await writer.calls == 0)
        #expect(draft.message == MobileTableActionError.contextChanged.localizedDescription)
        workspace.cancelAll()
    }

    @Test func unknownOutcomeSurvivesCloseAndReopenAndNeverRepeatsWithoutExplicitAcknowledgement() async throws {
        let writer = ActionWriter(mode: .unknown), workspace = await workspace(writer: writer), controller = workspace.tableActions
        await workspace.browser.selectObject(object)?.value
        controller.prepare(.truncate, object: object)
        let draft = try #require(controller.request); draft.confirmation = object.name; controller.safetyLock.disable()
        await controller.submit(draft)?.value
        #expect(draft.needsVerification); #expect(controller.blocksWrites); #expect(workspace.hasPendingChanges)
        #expect(controller.safetyLock.isEnabled); #expect(workspace.browser.currentChanges?.requiresReload == true)
        controller.dismiss(); controller.prepare(.drop, object: object)
        #expect(controller.request === draft); #expect(controller.submit(draft) == nil); #expect(await writer.calls == 1)
        controller.acknowledgeVerification(draft)
        #expect(!controller.blocksWrites); #expect(controller.request == nil)
    }

    @Test func backgroundBeforeSendCancelsWithoutLosingCapturedParametersOrAllowingAnotherSubmission() async throws {
        let writer = ActionWriter(mode: .holdBeforeSend), workspace = await workspace(writer: writer), controller = workspace.tableActions
        controller.prepare(.rename, object: object)
        let draft = try #require(controller.request); draft.input = "renamed"; controller.safetyLock.disable()
        let operation = try #require(controller.submit(draft)); #expect(await writer.waitForGate())
        controller.dismiss(); #expect(controller.request === draft)
        controller.prepare(.drop, object: object); #expect(controller.request === draft)
        workspace.setBackgrounded(true); #expect(controller.isSubmitting)
        await writer.release(); await operation.value
        #expect(!draft.hasCompleted); #expect(!draft.needsVerification); #expect(draft.input == "renamed")
        #expect(await writer.sent == 0); #expect(controller.safetyLock.isEnabled)
        workspace.setBackgrounded(false); #expect(await writer.calls == 1)
    }

    @Test func acknowledgedSuccessThenRefreshFailureCannotBeSubmittedAgain() async throws {
        let fixture = ActionFixture(), writer = ActionWriter(), workspace = await workspace(service: fixture, writer: writer)
        let controller = workspace.tableActions
        controller.prepare(.rename, object: object)
        let draft = try #require(controller.request); draft.input = "new"; controller.safetyLock.disable()
        await fixture.failNextCatalog()
        await controller.submit(draft)?.value
        #expect(draft.hasCompleted); #expect(draft.message?.contains("操作已完成") == true)
        #expect(!draft.needsVerification); #expect(controller.submit(draft) == nil); #expect(await writer.sent == 1)
        #expect(workspace.browser.catalog?.objects.contains { $0.name == "new" } == true)
        controller.dismiss(); #expect(controller.request == nil)
    }

    @Test func acknowledgedSuccessFinishingAfterBackgroundDoesNotBecomeUncertainOrRepeat() async throws {
        let writer = ActionWriter(mode: .holdAcknowledged), workspace = await workspace(writer: writer), controller = workspace.tableActions
        await workspace.browser.selectObject(object)?.value
        controller.prepare(.clear, object: object)
        let draft = try #require(controller.request); draft.confirmation = object.name; controller.safetyLock.disable()
        let operation = try #require(controller.submit(draft)); #expect(await writer.waitForGate())
        workspace.setBackgrounded(true); await writer.release(); await operation.value
        #expect(draft.hasCompleted); #expect(!draft.needsVerification); #expect(controller.submit(draft) == nil)
        #expect(workspace.browser.currentChanges?.requiresReload == true)
        workspace.setBackgrounded(false); #expect(await writer.sent == 1)
    }
}

actor ActionFixture: MobileMySQLServicing {
    private var failCatalog = false
    private var names = ["t", "other"]
    func apply(_ statement: WorkspaceTableActionStatement, object: MobileDatabaseObject) {
        names.removeAll { $0 == object.name }
        if let result = statement.resultingSelection { names.append(result.objectName) }
    }
    func failNextCatalog() { failCatalog = true }
    func databases(configuration: MariaDBTransportConfiguration) async throws -> [String] { ["db", "elsewhere"] }
    func objects(configuration: MariaDBTransportConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        if failCatalog { failCatalog = false; throw CocoaError(.fileReadUnknown) }
        return .init(objects: names.map { .init(database: database, name: $0, kind: .table, comment: "") }, hasMore: false)
    }
    func columns(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] {
        [.init(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "auto_increment", comment: ""),
         .init(name: "name", type: "varchar(80)", isNullable: true, key: "", defaultValue: nil, extra: "", comment: "")]
    }
    func page(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int,
              sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        .init(object: object, preview: .init(result: .init(columns: ["id","name"], rows: [["1","before"]])), columns: columns,
              offset: offset, pageSize: size, hasNextPage: false, hasStableOrder: true)
    }
}
actor ActionWriter: MobileTableActionServicing {
    enum Mode { case normal, unknown, holdBeforeSend, holdAcknowledged }
    private let mode: Mode
    private var fixture: ActionFixture?
    func bind(_ fixture: ActionFixture) { self.fixture = fixture }
    private(set) var calls = 0, sent = 0
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode = .normal) { self.mode = mode }
    func inspect(object: MobileDatabaseObject, configuration: MariaDBTransportConfiguration) async throws -> MobileTableActionInfo {
        .init(nextAutoIncrement: "43", hasAutoIncrement: true)
    }
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func perform(action: WorkspaceTableAction, object: MobileDatabaseObject, input: String, configuration: MariaDBTransportConfiguration,
                 authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceTableActionStatement {
        calls += 1; try await authorize()
        if mode == .holdBeforeSend { waiting = true; await withCheckedContinuation { continuation = $0 }; try Task.checkCancellation(); try await authorize() }
        sent += 1
        if mode == .unknown { throw MobileTableActionError.outcomeUnknown("lost acknowledgement") }
        if mode == .holdAcknowledged { waiting = true; await withCheckedContinuation { continuation = $0 } }
        let statement = try WorkspaceTableActionStatement.make(action: action, selection: object.editingSelection, databaseType: .mysql, input: input)
        await fixture?.apply(statement, object: object)
        return statement
    }
}
