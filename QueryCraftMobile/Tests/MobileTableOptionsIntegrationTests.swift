import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileTableOptionsIntegrationTests {
    private func create(_ name: String) async throws -> MobileDatabaseObject {
        let f = MobileSchemaIntegrationTests()
        _ = try await f.write("CREATE TABLE " + MobileMySQLService.identifier(name) + " (id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(80)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin ROW_FORMAT=DYNAMIC AUTO_INCREMENT=41 COMMENT='original' AVG_ROW_LENGTH=128 MIN_ROWS=1 MAX_ROWS=100")
        _ = try await f.write("INSERT INTO " + MobileMySQLService.identifier(name) + "(title) VALUES ('保留数据')")
        return f.object(name)
    }
    private func state(_ snapshot: MobileSchemaSnapshot) -> WorkspaceDatabaseSchemaEditorState {
        var state = WorkspaceDatabaseSchemaEditorState()
        state.reset(columns: snapshot.columns, indexes: snapshot.indexes, schemaChoices: snapshot.choices, tableOptions: snapshot.options)
        return state
    }
    private func plan(_ state: WorkspaceDatabaseSchemaEditorState, _ object: MobileDatabaseObject) -> WorkspaceDatabaseSchemaExecutionPlan {
        MySQLSchemaEditingProvider().makeExecutionPlan(for: .init(selection: object.editingSelection, columns: state.columns, indexes: state.indexes, tableOptionsChange: state.tableOptionsChange))
    }
    @Test func engineRowFormatCommentAutoIncrementAndAdvancedOptionsRoundTripWithoutLosingRows() async throws {
        let f = MobileSchemaIntegrationTests(), o = try await create("选项`roundtrip"), service = MobileSchemaService()
        let before = try await service.load(object: o, configuration: f.config()), original = try #require(before.options)
        #expect(original.engine == "InnoDB"); #expect(original.collation == "utf8mb4_bin"); #expect(original.comment == "original")
        var edited = state(before)
        edited.tableOptions.engine = "MyISAM"; edited.tableOptions.rowFormat = "DYNAMIC"; edited.tableOptions.comment = "表'选项雪"
        edited.tableOptions.autoIncrement = "300"; edited.tableOptions.averageRowLength = "256"; edited.tableOptions.minimumRows = "2"; edited.tableOptions.maximumRows = "999"; edited.tableOptions.keyBlockSize = "4"
        let capture = plan(edited,o); #expect(capture.statements.count == 1)
        try await service.apply(object: o, baseline: before, plan: capture, configuration: f.config(), authorize: {})
        let after = try await service.load(object: o, configuration: f.config()), options = try #require(after.options)
        #expect(options.engine == "MyISAM"); #expect(options.rowFormat == "DYNAMIC"); #expect(options.comment == "表'选项雪")
        #expect(options.averageRowLength == "256"); #expect(options.minimumRows == "2"); #expect(options.maximumRows == "999"); #expect(options.keyBlockSize == "4")
        #expect(try await f.write("SELECT id,title FROM " + MobileMySQLService.identifier(o.name)).rows == [["41","保留数据"]])
        #expect(try await f.write("INSERT INTO " + MobileMySQLService.identifier(o.name) + "(title) VALUES ('next')").insertID == 300)
        var reset = state(try await service.load(object: o, configuration: f.config()))
        let resetBaseline = try await service.load(object: o, configuration: f.config())
        reset.tableOptions.comment = ""; reset.tableOptions.averageRowLength = ""; reset.tableOptions.minimumRows = ""; reset.tableOptions.maximumRows = ""; reset.tableOptions.keyBlockSize = ""
        try await service.apply(object: o, baseline: resetBaseline, plan: plan(reset,o), configuration: f.config(), authorize: {})
        let final = try await service.load(object: o, configuration: f.config())
        #expect(final.options?.comment == ""); #expect(final.options?.minimumRows != "2")
        #expect(final.options?.maximumRows != "999"); #expect(final.options?.keyBlockSize != "4")
        #expect(try await f.write("SELECT COUNT(*) FROM " + MobileMySQLService.identifier(o.name)).rows == [["2"]])
    }
    @Test func tableDefaultCharsetAndCollationDoNotConvertExistingColumnOrRewriteUnchangedAutoCounter() async throws {
        let f = MobileSchemaIntegrationTests(), o = try await create("options_charset"), service = MobileSchemaService()
        let before = try await service.load(object: o, configuration: f.config()); var edited = state(before)
        edited.tableOptions.applyCharacterSet("latin1", choices: before.choices)
        edited.tableOptions.comment = "changed"
        let capture = plan(edited,o); #expect(!capture.statements[0].sql.contains("AUTO_INCREMENT")); #expect(!capture.statements[0].sql.contains("CONVERT TO"))
        _ = try await f.write("INSERT INTO options_charset(title) VALUES ('concurrent insert')")
        try await service.apply(object: o, baseline: before, plan: capture, configuration: f.config(), authorize: {})
        let after = try await service.load(object: o, configuration: f.config())
        #expect(after.options?.characterSet == "latin1"); #expect(after.options?.collation == "latin1_swedish_ci")
        #expect(after.columns.first { $0.name == "title" }?.collation == "utf8mb4_bin")
        #expect(try await f.write("SELECT title FROM options_charset ORDER BY id").rows == [["保留数据"],["concurrent insert"]])
    }
    @Test func staleExplicitOptionAndDeniedAlterKeepServerAndDraftUnchanged() async throws {
        let f = MobileSchemaIntegrationTests(), o = try await create("options_stale"), service = MobileSchemaService()
        let before = try await service.load(object: o, configuration: f.config()); var edited = state(before); edited.tableOptions.comment = "ours"
        _ = try await f.write("ALTER TABLE options_stale COMMENT='external'")
        await #expect(throws: MobileSchemaError.self) { try await service.apply(object: o, baseline: before, plan: plan(edited,o), configuration: f.config(), authorize: {}) }
        let current = try await service.load(object: o, configuration: f.config()); #expect(current.options?.comment == "external")
        var denied = state(current); denied.tableOptions.comment = "denied"
        do { try await service.apply(object: o, baseline: current, plan: plan(denied,o), configuration: f.config(reader: true), authorize: {}); Issue.record("ALTER must be denied") }
        catch let error as CDatabaseClientError { #expect(error.code == 1142) }
        #expect(try await service.load(object: o, configuration: f.config()).options?.comment == "external")
    }
    @Test func actualAlterWithLostAckFencesOptionsUntilExplicitReconcileThenLoadsRealValues() async throws {
        let f = MobileSchemaIntegrationTests(), o = try await create("options_unknown")
        let faulty = MobileSchemaService(makeConnection: { OptionsLostAck(client: MariaDBClient(configuration: $0)) })
        let c = MobileSchemaController(configuration: try f.config(), safetyLock: .init(), service: faulty)
        let context = UUID(); c.contextID = { context }; c.isCurrent = { _ in true }; c.hasPendingData = { _ in false }; c.allowsWrites = { true }
        await c.load(o)?.value; let d = c.draft(for: o); var updated = d.state.tableOptions; updated.comment = "actually changed"; d.updateOptions(updated)
        c.safetyLock.disable(); await c.submit(d)?.value
        #expect(d.needsVerification); #expect(c.blocksWrites); #expect(c.safetyLock.isEnabled); #expect(c.submit(d) == nil)
        #expect(try await MobileSchemaService().load(object: o, configuration: f.config()).options?.comment == "actually changed")
        #expect(c.load(o) == nil); await c.load(o, reconcile: true)?.value
        #expect(!d.needsVerification); #expect(!d.hasChanges); #expect(d.state.tableOptions.comment == "actually changed")
    }
    @Test func appOptionsCommitUpdatesSidebarCommentAndKeepsObjectSelectionAndDataDraftGuard() async throws {
        let f = MobileSchemaIntegrationTests(), config = try f.config(), o = try await create("options_navigation")
        let profile = MobileConnectionProfile(id: UUID(), name: "owned options", host: config.host, port: config.port, username: config.username, database: o.database, tlsMode: .required, remembersPassword: false, requiresPassword: true)
        let app = MobileApplicationModel(); app.open(profile, suppliedPassword: config.password); let w = try #require(app.workspace)
        await w.browser.loadDatabases().value; await w.browser.loadObjects()?.value; app.destination = .table(o); await w.browser.loadTable()?.value
        w.browser.tab = .structure; await w.browser.loadTable()?.value
        let d = w.schema.draft(for: o); #expect(d.snapshot?.options?.comment == "original")
        var options = d.state.tableOptions; options.comment = "updated sidebar"; d.updateOptions(options)
        #expect(w.hasPendingChanges); #expect(!w.browser.allowsDataMutation()); w.browser.safetyLock.disable(); await w.schema.submit(d)?.value
        #expect(!d.hasChanges); #expect(!d.requiresReload); #expect(w.browser.selectedObject?.id == o.id)
        #expect(w.browser.selectedObject?.comment == "updated sidebar")
        #expect(w.browser.catalog?.objects.first { $0.id == o.id }?.comment == "updated sidebar")
        if case .table(let route) = app.destination { #expect(route.comment == "updated sidebar") } else { Issue.record("must keep selected table") }
        w.cancelAll()
    }
}
private struct OptionsLostAck: MobileMutationConnection {
    let client: MariaDBClient
    func connect() async throws { try await client.connect() }
    func close() async { await client.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        let result = try await client.query(sql)
        if sql.hasPrefix("ALTER TABLE") { throw URLError(.networkConnectionLost) }
        return result
    }
}
