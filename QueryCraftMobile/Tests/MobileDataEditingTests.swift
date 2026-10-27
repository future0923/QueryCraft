import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

struct MobileDataEditingTests {
    private func config(user: String = "proof_writer") throws -> MobileSQLConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        return .init(host: MobileFixtureEndpoint.host, port: port, username: user,
            password: user == "proof_writer" ? "querycraft-proof-writer" : "querycraft-proof-reader",
            database: "querycraft_ios_edit", tlsMode: .required)
    }
    private func object(_ name: String, kind: MobileDatabaseObject.Kind = .table) -> MobileDatabaseObject {
        .init(database: "querycraft_ios_edit", name: name, kind: kind, comment: "")
    }
    private func page(_ name: String) async throws -> MobileTableSnapshot {
        let config = try config(), service = MobileMySQLService(), object = object(name)
        let columns = try await service.columns(configuration: config, object: object)
        return try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100,
            sortColumn: nil, ascending: true, filter: .empty)
    }
    private func query(_ sql: String) async throws -> CDatabaseQueryResult {
        try await MobileMariaDBExecutor().execute(configuration: config(), sql: sql)
    }
    @Test @MainActor func realCellStageDefaultNullRawIDAndCommit() async throws {
        let page = try await page("edit_rows")
        let lock = WorkspaceSafetyLock(), model = MobileTableChanges(object: page.object, metadata: page.columns,
            configuration: try config(), safetyLock: lock)
        let request = try model.request(page: page, row: 0, column: 1)
        #expect(request.primaryKey.first?.value == .text("318987599031067570"))
        let value = "quote'\\\n雪\u{0}"
        try model.stage(request, text: value, mode: .value)
        #expect(model.changeCount == 1)
        #expect(try await query("SELECT name FROM edit_rows").rows.first?.first == "original")
        #expect(model.submit() == nil); #expect(model.hasChanges)
        let grid = model.displayData(page: page, details: nil)
        #expect(grid.cell(row: 0, column: 1) == .text(value))
        #expect(grid.pendingCells.contains(.init(row: 0, column: 1)))
        let repeated = try model.request(page: page, row: 0, column: 1)
        #expect(repeated.initialText == value); #expect(repeated.originalValue == .text("original"))
        lock.disable(); await model.submit()?.value
        #expect(!model.hasChanges); #expect(model.message == nil)
        #expect(try await query("SELECT name FROM edit_rows").rows.first?.first == value)
        // Same shared NULL/default preparation; no integer/floating conversion.
        let fresh = try await self.page("edit_rows")
        try model.stage(model.request(page: fresh, row: 0, column: 1), text: "", mode: .null)
        try model.stage(model.request(page: fresh, row: 0, column: 2), text: "", mode: .useDefault)
        #expect(model.changeSet.rowUpdates.count == 1)
        await model.submit()?.value
        #expect(model.message == nil)
        let result = try await query("SELECT name,amount FROM edit_rows")
        #expect(result.rows[0][0] == nil); #expect(result.rows[0][1] == "1.25")
    }
    @Test @MainActor func insertDefaultsAndStagedDeleteRestoreUseSharedRequests() async throws {
        let page = try await page("edit_defaults"), lock = WorkspaceSafetyLock()
        let model = MobileTableChanges(object: page.object, metadata: page.columns, configuration: try config(), safetyLock: lock)
        let draft = try model.newInsert()
        #expect(draft.request.columns.first?.initialDraft.mode == .useDefault)
        draft.set(.init(mode: .value, text: "7"), column: "required_value")
        try model.stage(draft)
        #expect(model.changeSet.inserts[0].values.map(\.columnName) == ["required_value"])
        #expect(try await query("SELECT * FROM edit_defaults").rows.isEmpty)
        lock.disable(); await model.submit()?.value
        #expect(model.message == nil)
        let fresh = try await self.page("edit_defaults")
        #expect(fresh.preview.result.rows.count == 1)
        #expect(fresh.preview.result.rows[0][1] == "untouched"); #expect(fresh.preview.result.rows[0][2] == nil)
        try model.toggleDelete(page: fresh, row: 0)
        #expect(model.displayData(page: fresh, details: nil).deletedRows == [0])
        try model.toggleDelete(page: fresh, row: 0); #expect(!model.hasChanges)
        try model.toggleDelete(page: fresh, row: 0); await model.submit()?.value
        #expect(try await query("SELECT * FROM edit_defaults").rows.isEmpty)
    }
    @Test @MainActor func multiRowFailureRollsBackWholeTransactionAndKeepsDrafts() async throws {
        let page = try await page("edit_atomic"), lock = WorkspaceSafetyLock()
        let model = MobileTableChanges(object: page.object, metadata: page.columns, configuration: try config(), safetyLock: lock)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "must roll back", mode: .value)
        try model.stage(model.request(page: page, row: 1, column: 2), text: "-1", mode: .value)
        lock.disable(); await model.submit()?.value
        #expect(model.hasChanges); #expect(model.message != nil); #expect(!model.needsVerification)
        #expect(try await query("SELECT name FROM edit_atomic WHERE id=1").rows[0][0] == "first")
        try model.stage(model.request(page: page, row: 1, column: 2), text: "30", mode: .value)
        await model.submit()?.value
        #expect(!model.hasChanges); #expect(model.message == nil)
        #expect(try await query("SELECT amount FROM edit_atomic WHERE id=2").rows[0][0] == "30")
    }
    @Test @MainActor func primaryKeyGroupingCompositeKeysAndGuardedTypes() async throws {
        let page = try await page("edit_composite"), lock = WorkspaceSafetyLock()
        let model = MobileTableChanges(object: page.object, metadata: page.columns, configuration: try config(), safetyLock: lock)
        let key = try model.request(page: page, row: 0, column: 1)
        try model.stage(key, text: "318987599031067571", mode: .value)
        try model.stage(model.request(page: page, row: 0, column: 2), text: "updated", mode: .value)
        #expect(model.changeSet.rowUpdates.count == 1); #expect(model.changeSet.rowUpdates[0].assignments.count == 2)
        #expect(model.changeSet.rowUpdates[0].primaryKey.map(\.value) == [.text("1"), .text("318987599031067570")])
        lock.disable(); await model.submit()?.value; #expect(model.message == nil)
        let result = try await query("SELECT tenant,id,name FROM edit_composite ORDER BY tenant")
        #expect(result.rows[0] == ["1","318987599031067571","updated"])
        #expect(result.rows[1] == ["2","318987599031067570","two"])
        let types = try await self.page("edit_rows")
        let guarded = MobileTableChanges(object: types.object, metadata: types.columns, configuration: try config(), safetyLock: lock)
        #expect(throws: WorkspaceDatabaseDataCellEditError.binaryValueUnavailable) { try guarded.request(page: types, row: 0, column: 3) }
        #expect(throws: WorkspaceDatabaseDataCellEditError.generatedColumn) { try guarded.request(page: types, row: 0, column: 4) }
        let noKey = try await self.page("edit_nopk")
        let unkeyed = MobileTableChanges(object: noKey.object, metadata: noKey.columns, configuration: try config(), safetyLock: lock)
        #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyRequired) { try unkeyed.request(page: noKey, row: 0, column: 1) }
        #expect(throws: WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired) { try unkeyed.toggleDelete(page: noKey, row: 0) }
    }
    @Test @MainActor func metadataChangesAndUncertainCommitCannotBeResubmitted() async throws {
        let page = try await page("edit_myisam"), lock = WorkspaceSafetyLock()
        let writer = UnknownCommitWriter()
        let model = MobileTableChanges(object: page.object, metadata: page.columns, configuration: try config(), safetyLock: lock, service: writer)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "draft", mode: .value)
        lock.disable(); await model.submit()?.value
        #expect(model.needsVerification); #expect(model.hasChanges); #expect(!model.canSubmit); #expect(model.submit() == nil)
        #expect(await writer.calls == 1)
        model.discard(); #expect(!model.hasChanges); #expect(model.requiresReload)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try model.request(page: page, row: 0, column: 1) }
        model.receive(metadata: page.columns) // Successful raw table reload.
        #expect(!model.requiresReload)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "draft", mode: .value)
        model.receive(metadata: [])
        #expect(!model.canSubmit)
        #expect(throws: WorkspaceDatabaseDataCellEditError.self) { try model.newInsert() }
    }
    @Test @MainActor func pendingInsertCorrectionAndNavigationRetainIdentity() async throws {
        let browser = MobileBrowserModel(configuration: try config())
        defer { browser.cancelAll() }
        await browser.loadDatabases().value; await browser.loadObjects()?.value
        await browser.selectObject(object("edit_defaults"))?.value
        let first = try #require(browser.currentChanges)
        let draft = try first.newInsert()
        draft.set(.init(mode: .value, text: "bad"), column: "required_value"); try first.stage(draft)
        let edited = try first.editInsert(try #require(first.inserts.first))
        edited.set(.init(mode: .value, text: "8"), column: "required_value"); try first.stage(edited)
        #expect(first.inserts.count == 1); #expect(first.inserts[0].id == draft.id)
        #expect(first.inserts[0].value.values.first?.value == .text("8"))
        await browser.selectObject(object("edit_cancel"))?.value
        #expect(!first.canSubmit); #expect(first.hasChanges)
        await browser.selectObject(object("edit_defaults"))?.value
        #expect(browser.currentChanges === first); #expect(first.canSubmit)
        first.removeInsert(draft.id); #expect(!first.hasChanges)
    }

    @Test @MainActor func changingConnectionCannotSilentlyLoseDrafts() async throws {
        let configuration = try config()
        let profile = MobileConnectionProfile(id: UUID(), name: "owned", host: configuration.host, port: configuration.port,
            username: configuration.username, database: "querycraft_ios_edit", tlsMode: .required, remembersPassword: false, requiresPassword: true)
        let repository = EditingTestLibrary(profile: profile)
        let app = MobileApplicationModel(repository: repository, passwords: EditingTestPasswords())
        app.open(profile, suppliedPassword: "querycraft-proof-writer")
        let workspace = try #require(app.workspace)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        await workspace.browser.selectObject(object("edit_cancel"))?.value
        let model = try #require(workspace.browser.currentChanges), page = try #require(workspace.browser.snapshot)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "draft", mode: .value)
        app.showLibrary(); #expect(model.hasChanges); #expect(model.safetyLock.isEnabled)
        let other = MobileConnectionProfile(id: UUID(), name: "other", host: profile.host, port: profile.port,
            username: profile.username, database: profile.database, tlsMode: profile.tlsMode,
            remembersPassword: false, requiresPassword: true)
        app.open(other, suppliedPassword: "querycraft-proof-writer")
        #expect(app.workspace === workspace); #expect(!app.isWorkspacePresented); #expect(app.message != nil)
        #expect(throws: MobileDataMutationError.self) { try app.delete(profile) }
        app.open(profile, suppliedPassword: "querycraft-proof-writer")
        #expect(app.workspace === workspace); #expect(model.hasChanges)
        model.discard(); workspace.cancelAll()
    }

    @Test func nonTransactionalEngineAndUnauthorizedConnectionNeverWrite() async throws {
        let page = try await page("edit_myisam")
        let update = WorkspaceDatabaseDataCellUpdate(selection: page.object.editingSelection, columnName: "name",
            originalValue: .text("unchanged"), newValue: .text("forbidden"), primaryKey: [.init(columnName: "id", value: .text("1"))])
        let changes = WorkspaceDatabaseDataChangeSet(updates: [update], inserts: [], deletes: [])
        await #expect(throws: MobileDataMutationError.nonTransactionalTable) {
            try await MobileDataMutationService().apply(changes, configuration: config(), authorize: {})
        }
        await #expect(throws: WorkspaceDatabaseDataCellEditError.safetyLockEnabled) {
            try await MobileDataMutationService().apply(changes, configuration: config()) { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled }
        }
        #expect(try await query("SELECT name FROM edit_myisam").rows[0][0] == "unchanged")
        let denied = WorkspaceDatabaseDataChangeSet(updates: [.init(selection: object("edit_cancel").editingSelection,
            columnName: "name", originalValue: .text("first"), newValue: .text("denied"), primaryKey: [.init(columnName: "id", value: .text("1"))])], inserts: [], deletes: [])
        await #expect(throws: CDatabaseClientError.self) {
            try await MobileDataMutationService().apply(denied, configuration: config(user: "proof_reader"), authorize: {})
        }
        #expect(try await query("SELECT name FROM edit_cancel WHERE id=1").rows[0][0] == "first")
    }
    @Test func cancellationAfterFirstWriteRollsBackBeforeConnectionCloses() async throws {
        let page = try await page("edit_cancel")
        let changes = WorkspaceDatabaseDataChangeSet(updates: try page.preview.result.rows.map { row in
            .init(selection: page.object.editingSelection, columnName: "name", originalValue: .text(try #require(row[1])), newValue: .text("rollback"),
                primaryKey: [.init(columnName: "id", value: .text(try #require(row[0])))])
        }, inserts: [], deletes: [])
        let gate = MutationAuthorizationGate(), config = try config()
        let operation = Task { try await MobileDataMutationService().apply(changes, configuration: config) { try await gate.authorize() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isWaiting), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.isWaiting)
        operation.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try await query("SELECT name FROM edit_cancel ORDER BY id").rows == [["first"],["second"]])
    }
}

private actor UnknownCommitWriter: MobileDataMutating {
    var calls = 0
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MobileSQLConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws {
        try await authorize(); calls += 1; throw MobileDataMutationError.uncertainCommit
    }
}
private actor MutationAuthorizationGate {
    var calls = 0
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func authorize() async throws {
        calls += 1
        if calls == 5 { isWaiting = true; await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class EditingTestLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(profile: MobileConnectionProfile) { state = .init(profiles: [profile]) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
@MainActor private final class EditingTestPasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws {}
}
