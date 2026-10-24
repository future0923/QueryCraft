import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil))
struct MobilePostgreSQLMutationTests {
    private func config(reader: Bool = false) throws -> MobileSQLConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"].flatMap(Int.init))
        return .init(host: "127.0.0.1", port: port, username: reader ? "proof_reader" : "proof_writer",
                     password: reader ? "querycraft-proof-pg" : "querycraft-proof-pg-writer",
                     database: "querycraft_ios_pg", tlsMode: .disabled, driver: .postgresql)
    }
    private func object(schema: String = "mobile_edit", name: String = "records") -> MobileDatabaseObject {
        .init(database: "querycraft_ios_pg", name: name, kind: .table, comment: "", schemaName: schema)
    }
    @discardableResult private func query(_ sql: String) async throws -> PostgreSQLCQueryResult {
        let client = LibPQClient(configuration: try config().postgreSQL)
        do { try await client.connect(); let result = try await client.query(sql); await client.close(); return result }
        catch { await client.close(); throw error }
    }
    private func page(_ object: MobileDatabaseObject? = nil) async throws -> MobileTableSnapshot {
        let object = object ?? self.object(), config = try config(), service = MobilePostgreSQLService()
        let columns = try await service.columns(configuration: config, object: object)
        return try await service.page(configuration: config, object: object, columns: columns, offset: 0, size: 100,
                                      sortColumn: "id", ascending: true, filter: .empty)
    }
    private func reset() async throws -> MobileTableSnapshot {
        try await query("DELETE FROM mobile_edit.records")
        try await query("INSERT INTO mobile_edit.records(id,name,amount,nullable) VALUES (318987599031067570,'before',10,'present')")
        return try await page()
    }
    private func model(_ page: MobileTableSnapshot, reader: Bool = false,
                       service: MobilePostgreSQLMutationService = .init()) throws -> MobileTableChanges {
        .init(object: page.object, metadata: page.columns, configuration: try config(reader: reader),
              safetyLock: WorkspaceSafetyLock(), service: service)
    }
    @Test func realStagingUsesPhysicalSchemaRawPrimaryKeyNullAndDefault() async throws {
        let page = try await reset(), model = try model(page)
        let request = try model.request(page: page, row: 0, column: 1)
        #expect(request.primaryKey.first?.value == .text("318987599031067570"))
        let text = "O'Reilly\\雪 -- ;"
        try model.stage(request, text: text, mode: .value)
        try model.stage(model.request(page: page, row: 0, column: 4), text: "", mode: .null)
        #expect(model.changeSet.rowUpdates.count == 1)
        #expect(try model.previewSQL().contains("UPDATE \"mobile_edit\".\"records\""))
        #expect(model.submit() == nil)
        #expect(try await query("SELECT name FROM mobile_edit.records").rows[0][0] == "before")
        model.safetyLock.disable(); await model.submit()?.value
        #expect(model.message == nil); #expect(!model.hasChanges)
        #expect(try await query("SELECT name,nullable FROM mobile_edit.records").rows == [[text, nil]])
        #expect(try await query("SELECT name FROM mobile_other.records").rows[0][0] == "other schema")
        let fresh = try await self.page()
        try model.stage(model.request(page: fresh, row: 0, column: 1), text: "", mode: .useDefault)
        await model.submit()?.value
        #expect(model.message == nil)
        #expect(try await query("SELECT name,computed FROM mobile_edit.records").rows == [["default name", "default name!"]])
    }
    @Test func defaultIdentityInsertAndDeleteUseExistingDraftFlow() async throws {
        let page = try await reset(), model = try model(page), draft = try model.newInsert()
        #expect(draft.request.columns.first?.initialDraft.mode == .useDefault)
        #expect(!draft.request.columns.contains { $0.id == "computed" })
        draft.set(.init(mode: .value, text: "inserted"), column: "name")
        draft.set(.init(mode: .value, text: "1.50"), column: "amount")
        try model.stage(draft)
        #expect(model.changeSet.inserts[0].values.map(\.columnName) == ["name", "amount"])
        model.safetyLock.disable(); await model.submit()?.value
        #expect(model.message == nil); #expect(!model.hasChanges)
        let fresh = try await self.page()
        let inserted = try #require(fresh.preview.result.rows.firstIndex { $0[1] == "inserted" })
        #expect(fresh.preview.result.rows[inserted][2] == "1.50")
        #expect(fresh.preview.result.rows[inserted][5] == "inserted!")
        try model.toggleDelete(page: fresh, row: inserted); await model.submit()?.value
        #expect(model.message == nil)
        #expect(try await query("SELECT count(*) FROM mobile_edit.records").rows[0][0] == "1")
        let defaults = try model.newInsert(); try model.stage(defaults)
        #expect(try model.previewSQL() == "INSERT INTO \"mobile_edit\".\"records\" DEFAULT VALUES;")
        await model.submit()?.value; #expect(model.message == nil)
    }
    @Test func constraintFailureRollsBackEarlierDeleteAndRetainsDrafts() async throws {
        let page = try await reset(), model = try model(page)
        try model.toggleDelete(page: page, row: 0)
        let draft = try model.newInsert(); draft.set(.init(mode: .value, text: "-1"), column: "amount")
        try model.stage(draft); model.safetyLock.disable(); await model.submit()?.value
        #expect(model.hasChanges); #expect(!model.needsVerification); #expect(model.message != nil)
        #expect(try await query("SELECT name FROM mobile_edit.records").rows == [["before"]])
        let corrected = try model.editInsert(try #require(model.inserts.first))
        corrected.set(.init(mode: .value, text: "3"), column: "amount"); try model.stage(corrected)
        await model.submit()?.value; #expect(model.message == nil); #expect(!model.hasChanges)
        #expect(try await query("SELECT name,amount FROM mobile_edit.records").rows == [["default name", "3.00"]])
    }
    @Test func missingRowAndReadOnlyRoleFailWithoutUnknownCommit() async throws {
        let page = try await reset(), denied = try model(page, reader: true)
        try denied.stage(denied.request(page: page, row: 0, column: 1), text: "forbidden", mode: .value)
        denied.safetyLock.disable(); await denied.submit()?.value
        #expect(denied.hasChanges); #expect(denied.message != nil); #expect(!denied.needsVerification)
        #expect(try await query("SELECT name FROM mobile_edit.records").rows[0][0] == "before")
        let missing = try model(page)
        try missing.stage(missing.request(page: page, row: 0, column: 1), text: "missing", mode: .value)
        try await query("DELETE FROM mobile_edit.records")
        missing.safetyLock.disable(); await missing.submit()?.value
        #expect(missing.message == WorkspaceDatabaseDataCellEditError.rowChanged.localizedDescription)
        #expect(missing.hasChanges); #expect(!missing.needsVerification)
    }
    @Test func staleMetadataIsRejectedBeforeMutation() async throws {
        let page = try await reset(), model = try model(page)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "stale", mode: .value)
        var columns = page.columns
        columns.removeLast()
        let service = MobilePostgreSQLMutationService().scoped(to: page.object, columns: columns)
        await #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) {
            try await service.apply(model.changeSet, configuration: config(), authorize: {})
        }
        #expect(try await query("SELECT name FROM mobile_edit.records").rows[0][0] == "before")
    }
    @Test func dottedNamesStayDistinctAndMutateTheirPhysicalTarget() async throws {
        let target = object(schema: "edit.with.dot", name: "table.with.dot")
        #expect(target.editingSelection != object(schema: "edit", name: "with.dot.table.with.dot").editingSelection)
        try await query("DELETE FROM \"edit.with.dot\".\"table.with.dot\"")
        try await query("INSERT INTO \"edit.with.dot\".\"table.with.dot\"(id,name) VALUES(1,'before')")
        let page = try await page(target), model = try model(page)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "quoted target", mode: .value)
        model.safetyLock.disable(); await model.submit()?.value
        #expect(model.message == nil)
        #expect(try await query("SELECT name FROM \"edit.with.dot\".\"table.with.dot\"").rows[0][0] == "quoted target")
    }
    @Test func generatedColumnsAreGuardedAndByteaUsesDesktopTextRepresentation() async throws {
        let page = try await reset(), model = try model(page)
        #expect(throws: WorkspaceDatabaseDataCellEditError.generatedColumn) { try model.request(page: page, row: 0, column: 5) }
        try model.stage(model.request(page: page, row: 0, column: 3), text: "\\x0041ff", mode: .value)
        model.safetyLock.disable(); await model.submit()?.value
        #expect(model.message == nil)
        #expect(try await query("SELECT payload FROM mobile_edit.records").rows[0][0] == "\\x0041ff")
    }
    @Test func nulTextIsRejectedBeforeExecutingAnyBatchStatement() async throws {
        let page = try await reset(), model = try model(page)
        try model.stage(model.request(page: page, row: 0, column: 1), text: "invalid\u{0}text", mode: .value)
        #expect(throws: PostgreSQLDataMutation.ValidationError.self) { try model.previewSQL() }
        model.safetyLock.disable(); await model.submit()?.value
        #expect(model.hasChanges); #expect(!model.needsVerification)
        #expect(try await query("SELECT name FROM mobile_edit.records").rows[0][0] == "before")
    }
    @Test func noPrimaryKeyCannotUpdateOrDeleteAndViewsCannotStageWrites() async throws {
        let target = object(name: "no_primary_key"), service = MobilePostgreSQLService(), config = try config()
        let columns = try await service.columns(configuration: config, object: target)
        let page = try await service.page(configuration: config, object: target, columns: columns, offset: 0, size: 100, sortColumn: nil, ascending: true, filter: .empty)
        let model = try model(page)
        #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyRequired) { try model.request(page: page, row: 0, column: 0) }
        #expect(throws: WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired) { try model.toggleDelete(page: page, row: 0) }
        let view = MobileDatabaseObject(database: target.database, name: "user_view", kind: .view, comment: "", schemaName: "audit")
        let viewChanges = MobileTableChanges(object: view, metadata: columns, configuration: config, safetyLock: WorkspaceSafetyLock(), service: MobilePostgreSQLMutationService())
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try viewChanges.newInsert() }
    }
    @Test func lostCommitAcknowledgementRequiresReloadBeforeAnyNewWrites() async throws {
        let page = try await reset(), connection = PostgreSQLFaultConnection(configuration: try config(), mode: .lostCommit)
        let model = try model(page, service: .init(makeConnection: { _ in connection }))
        try model.stage(model.request(page: page, row: 0, column: 1), text: "committed", mode: .value)
        model.safetyLock.disable(); await model.submit()?.value
        #expect(try await query("SELECT name FROM mobile_edit.records").rows[0][0] == "committed")
        #expect(model.needsVerification); #expect(model.hasChanges); #expect(model.submit() == nil)
        #expect(await connection.statements.filter { $0 == "COMMIT" }.count == 1)
        model.discard(); #expect(model.requiresReload)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try model.newInsert() }
        let fresh = try await self.page(); model.receive(metadata: fresh.columns)
        #expect(!model.requiresReload)
    }
    @Test func backgroundAfterWriteRollsBackDespiteCancelledAuthorization() async throws {
        let page = try await reset(), connection = PostgreSQLFaultConnection(configuration: try config(), mode: .holdWrite)
        let model = try model(page, service: .init(makeConnection: { _ in connection }))
        try model.stage(model.request(page: page, row: 0, column: 1), text: "rolled back", mode: .value)
        model.safetyLock.disable(); let operation = try #require(model.submit())
        let waiting = await connection.waitForGate()
        model.interruptSubmission(); await connection.release(); await operation.value
        #expect(waiting); #expect(model.hasChanges); #expect(!model.needsVerification)
        #expect(await connection.statements.contains("ROLLBACK"))
        #expect(!(await connection.statements.contains("COMMIT")))
        #expect(try await query("SELECT name FROM mobile_edit.records").rows[0][0] == "before")
    }
}

private actor PostgreSQLFaultConnection: MobileMutationConnection {
    enum Mode { case lostCommit, holdWrite }
    private let client: MobilePostgreSQLMutationConnection
    private let mode: Mode
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false
    private(set) var statements: [String] = []
    init(configuration: MobileSQLConfiguration, mode: Mode) {
        client = .init(client: LibPQClient(configuration: configuration.postgreSQL)); self.mode = mode
    }
    func connect() async throws { try await client.connect() }
    func close() async { await client.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        statements.append(sql)
        let result = try await client.query(sql, bindings: bindings)
        if sql == "COMMIT", mode == .lostCommit { throw URLError(.networkConnectionLost) }
        if sql.hasPrefix("UPDATE"), mode == .holdWrite {
            waiting = true; await withCheckedContinuation { continuation = $0 }; try Task.checkCancellation()
        }
        return result
    }
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
}
