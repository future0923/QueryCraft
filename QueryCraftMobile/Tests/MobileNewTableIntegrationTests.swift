import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileNewTableIntegrationTests {
    private func draft(_ name: String) throws -> MobileNewTableDraft {
        let d = MobileNewTableDraft(database: "querycraft_ios_table_actions"); d.definition.tableName = name
        let col = try #require(d.definition.editor.columns.first); var def = col.definition
        def.name = "id"; def.type = "BIGINT"; def.isAutoIncrement = true
        d.definition.editor.updateColumn(id: col.id, definition: def); d.definition.editor.setPrimaryKey(columnID: col.id, isEnabled: true)
        return d
    }
    @Test func realCreateRoundTripsEscapedNamesDefaultsGeneratedColumnsIndexesAndAllOptions() async throws {
        let fixture = MobileSchemaIntegrationTests(), name = "新建`表;完整", d = try draft(name), service = MobileNewTableService()
        let choices = try await service.choices(configuration: fixture.config())
        #expect(choices.engines.contains("InnoDB")); #expect(choices.characterSets.contains("utf8mb4"))
        #expect(choices.collations.contains { $0.name == "utf8mb4_bin" })
        let id = d.definition.editor.addColumn(); var column = try #require(d.definition.editor.columns.first { $0.id == id }).definition
        column.name = "名称`值"; column.type = "VARCHAR(80)"; column.defaultMode = .value; column.defaultValue = "默认'雪"; column.comment = "字段'注释"
        d.definition.editor.updateColumn(id: id, definition: column)
        let generated = d.definition.editor.addColumn(); var g = try #require(d.definition.editor.columns.first { $0.id == generated }).definition
        g.name = "name_len"; g.type = "INT"; g.generatedStorage = .stored; g.generationExpression = "CHAR_LENGTH(`名称``值`)"
        d.definition.editor.updateColumn(id: generated, definition: g)
        let index = d.definition.editor.addIndex(); var idx = try #require(d.definition.editor.indexes.first { $0.id == index }).definition
        idx.name = "索引`名"; idx.comment = "索引注释"; idx.columns = [.init(name: column.name, sourceColumnID: id)]
        idx.columns[0].prefixLength = "20"; idx.columns[0].isDescending = true; d.definition.editor.updateIndex(id: index, definition: idx)
        d.definition.options = .init(engine: "InnoDB", characterSet: "utf8mb4", collation: "utf8mb4_bin", rowFormat: "DYNAMIC", autoIncrement: "81", comment: "表'注释", averageRowLength: "128", minimumRows: "1", maximumRows: "1000", keyBlockSize: "0")
        let selection = try await service.create(plan: d.plan, configuration: fixture.config(), authorize: {})
        #expect(selection.objectName == name)
        let object = fixture.object(name), snapshot = try await MobileSchemaService().load(object: object, configuration: fixture.config())
        #expect(snapshot.columns.map(\.name) == ["id",column.name,"name_len"])
        #expect(snapshot.columns[1].defaultValue == "默认'雪"); #expect(snapshot.columns[1].comment == "字段'注释")
        #expect(!snapshot.columns[2].generationExpression.isEmpty)
        let actual = try #require(snapshot.indexes.first { $0.name == idx.name }); #expect(actual.columns[0].prefixLength == 20); #expect(actual.columns[0].direction == "D"); #expect(actual.comment == "索引注释")
        let inserted = try await fixture.write("INSERT INTO " + MobileMySQLService.identifier(name) + " () VALUES ()")
        #expect(inserted.insertID == 81)
        #expect(try await fixture.write("SELECT `名称``值`,name_len FROM " + MobileMySQLService.identifier(name)).rows == [["默认'雪","4"]])
        #expect(snapshot.ddl.contains("ENGINE=InnoDB")); #expect(snapshot.ddl.contains("utf8mb4_bin")); #expect(snapshot.ddl.contains("ROW_FORMAT=DYNAMIC"))
    }
    @Test func duplicateAndPermissionErrorsAreKnownRejectionsAndNeverReplaceExistingTable() async throws {
        let f = MobileSchemaIntegrationTests(), d = try draft("new_table_duplicate"), s = MobileNewTableService()
        _ = try await s.create(plan: d.plan, configuration: f.config(), authorize: {})
        do { _ = try await s.create(plan: d.plan, configuration: f.config(), authorize: {}); Issue.record("duplicate must fail") }
        catch let error as CDatabaseClientError { #expect(error.code == 1050) }
        d.definition.tableName = "new_table_denied"
        do { _ = try await s.create(plan: d.plan, configuration: f.config(reader: true), authorize: {}); Issue.record("reader must fail") }
        catch let error as CDatabaseClientError { #expect(error.code == 1142) }
        #expect(try await f.write("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='querycraft_ios_table_actions' AND TABLE_NAME='new_table_denied'").rows == [["0"]])
    }
    @Test func invalidDefinitionAndFinalAuthorizationRefuseDDLOnRealConnection() async throws {
        let f = MobileSchemaIntegrationTests(), d = try draft("new_table_not_sent"), gate = NewTableAuthorizationGate(), s = MobileNewTableService()
        await #expect(throws: WorkspaceDatabaseDataCellEditError.safetyLockEnabled) {
            _ = try await s.create(plan: d.plan, configuration: f.config(), authorize: { try await gate.authorize() })
        }
        #expect(await gate.calls == 2)
        d.definition.tableName = ""
        await #expect(throws: MobileNewTableError.self) { _ = try await s.create(plan: d.plan, configuration: f.config(), authorize: {}) }
        #expect(try await f.write("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='querycraft_ios_table_actions' AND TABLE_NAME='new_table_not_sent'").rows == [["0"]])
    }
    @Test func actualAutoCommittedCreateWithLostAckStaysFencedAcrossReopen() async throws {
        let f = MobileSchemaIntegrationTests(), connection = NewTableLostAck(client: MariaDBClient(configuration: try f.config()))
        let c = MobileNewTableController(configuration: try f.config(), safetyLock: .init(), service: MobileNewTableService(makeConnection: { _ in connection }))
        let context = UUID(); c.contextID = { context }; c.isCurrent = { _ in true }; c.allowsWrites = { true }
        c.present(database: "querycraft_ios_table_actions"); let d = try #require(c.request)
        d.definition.tableName = "new_table_lost_ack"; let item = try #require(d.definition.editor.columns.first); var def = item.definition; def.name = "id"
        c.editingContext(d).updateColumn(item.id, def, false); c.safetyLock.disable(); await c.submit(d, plan: d.plan)?.value
        #expect(d.needsVerification); #expect(!d.hasCompleted); #expect(c.safetyLock.isEnabled)
        #expect(try await f.write("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='querycraft_ios_table_actions' AND TABLE_NAME='new_table_lost_ack'").rows == [["1"]])
        c.dismiss(); c.present(database: "querycraft_ios_table_actions"); #expect(c.request === d)
        c.safetyLock.disable(); #expect(c.submit(d, plan: d.plan) == nil); #expect(await connection.sent == 1)
    }
    @Test func appCreateRefreshesCatalogSelectsNewEmptyTableAndClearsSearch() async throws {
        let config = try MobileSchemaIntegrationTests().config()
        let profile = MobileConnectionProfile(id: UUID(), name: "owned create", host: config.host, port: config.port, username: config.username, database: config.database ?? "", tlsMode: .required, remembersPassword: false, requiresPassword: true)
        let app = MobileApplicationModel(repository: NewTableLibrary(profile), passwords: NewTablePasswords())
        app.open(profile, suppliedPassword: config.password); let w = try #require(app.workspace)
        await w.browser.loadDatabases().value; await w.browser.loadObjects()?.value
        w.browser.search = "does_not_match"; let c = w.newTable; c.present(database: "querycraft_ios_table_actions"); let d = try #require(c.request)
        d.definition.tableName = "new_table_navigation"; let item = try #require(d.definition.editor.columns.first); var def = item.definition; def.name = "title"
        c.editingContext(d).updateColumn(item.id, def, false); c.safetyLock.disable(); await c.submit(d, plan: d.plan)?.value
        #expect(d.hasCompleted); #expect(d.message == "表已创建"); #expect(c.request == nil); #expect(w.browser.search.isEmpty)
        let object = try #require(w.browser.selectedObject); #expect(object.name == "new_table_navigation"); #expect(app.destination == .table(object))
        #expect(w.browser.catalog?.objects.contains { $0.name == object.name } == true)
        #expect(w.browser.snapshot?.preview.result.rows.isEmpty == true); #expect(w.browser.snapshot?.preview.result.columns == ["title"])
        w.cancelAll()
    }
}
private actor NewTableAuthorizationGate {
    private(set) var calls = 0
    func authorize() throws { calls += 1; if calls == 2 { throw WorkspaceDatabaseDataCellEditError.safetyLockEnabled } }
}
private actor NewTableLostAck: MobileMutationConnection {
    let client: MariaDBClient
    private(set) var sent = 0
    init(client: MariaDBClient) { self.client = client }
    func connect() async throws { try await client.connect() }
    func close() async { await client.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        let result = try await client.query(sql)
        if sql.hasPrefix("CREATE TABLE") { sent += 1; await client.close(); throw URLError(.networkConnectionLost) }
        return result
    }
}
@MainActor private final class NewTableLibrary: MobileLibraryPersisting {
    var state: MobileLibraryState
    init(_ p: MobileConnectionProfile) { state = .init(profiles: [p]) }
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}
@MainActor private final class NewTablePasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws {}
}
