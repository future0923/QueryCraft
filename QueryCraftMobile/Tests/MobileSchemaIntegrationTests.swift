import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileSchemaIntegrationTests {
    func config(reader: Bool = false) throws -> MobileSQLConfiguration {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        return .init(host: MobileFixtureEndpoint.host, port: port, username: reader ? "proof_reader" : "proof_table_admin",
                     password: reader ? "querycraft-proof-reader" : "querycraft-proof-table-admin", database: "querycraft_ios_table_actions", tlsMode: .required)
    }
    func object(_ name: String) -> MobileDatabaseObject { .init(database: "querycraft_ios_table_actions", name: name, kind: .table, comment: "") }
    func write(_ sql: String) async throws -> CDatabaseQueryResult {
        let c = MariaDBClient(configuration: try config())
        do { try await c.connect(); let r = try await c.query(sql); await c.close(); return r }
        catch { await c.close(); throw error }
    }
    func apply(_ state: WorkspaceDatabaseSchemaEditorState, to object: MobileDatabaseObject, baseline: MobileSchemaSnapshot,
               service: MobileSchemaService = .init(), reader: Bool = false, authorize: @escaping @Sendable () async throws -> Void = {}) async throws {
        let changes = WorkspaceDatabaseSchemaChangeSet(selection: object.editingSelection, columns: state.columns, indexes: state.indexes)
        try await service.apply(object: object, baseline: baseline, plan: MySQLSchemaEditingProvider().makeExecutionPlan(for: changes), configuration: config(reader: reader), authorize: authorize)
    }
    @Test func fieldRenameTypeDefaultCommentNullAndGeneratedMetadataAreRealAndPreserved() async throws {
        let o = object("schema_columns"), service = MobileSchemaService()
        let before = try await service.load(object: o, configuration: config())
        #expect(before.columns.first { $0.name == "generated_len" }?.generationExpression.isEmpty == false)
        #expect(before.columns.first { $0.name == "hidden_value" }?.extra.lowercased().contains("invisible") == true)
        var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes, schemaChoices: before.choices)
        let title = try #require(state.columns.first { $0.definition.name == "title" })
        var d = title.definition; d.name = "新`名称"; d.type = "VARCHAR(120)"; d.defaultMode = .value; d.defaultValue = "新默认'值"; d.comment = "新注释"; d.isNullable = true
        state.updateColumn(id: title.id, definition: d)
        let generated = try #require(state.columns.first { $0.definition.name == "generated_len" })
        var g = generated.definition; g.comment = "生成注释"; state.updateColumn(id: generated.id, definition: g)
        // Existing generated reference to title prevents rename on MySQL. Change a separate field instead.
        d.name = "title"; state.updateColumn(id: title.id, definition: d)
        let note = try #require(state.columns.first { $0.definition.name == "note" }); var n = note.definition; n.name = "新`名称"; state.updateColumn(id: note.id, definition: n)
        try await apply(state, to: o, baseline: before)
        let after = try await service.load(object: o, configuration: config())
        #expect(after.columns.first { $0.name == "新`名称" } != nil)
        #expect(after.columns.first { $0.name == "title" }?.defaultValue == "新默认'值")
        #expect(after.columns.first { $0.name == "title" }?.comment == "新注释")
        #expect(after.columns.first { $0.name == "generated_len" }?.generationExpression == before.columns.first { $0.name == "generated_len" }?.generationExpression)
        #expect(after.columns.first { $0.name == "hidden_value" } == before.columns.first { $0.name == "hidden_value" })
        #expect(try await write("SELECT generated_len FROM schema_columns").rows == [["3"]])
    }
    @Test func addDeleteAndRestoreFieldsUseActualSharedStatements() async throws {
        let o = object("schema_add_drop"), s = MobileSchemaService(), before = try await s.load(object: o, configuration: config())
        var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes)
        let gone = try #require(state.columns.first { $0.definition.name == "remove_me" }); state.deleteColumn(id: gone.id); state.restoreDeletion(id: gone.id)
        #expect(!state.hasChanges); state.deleteColumn(id: gone.id)
        let id = state.addColumn(); var d = try #require(state.columns.first { $0.id == id }).definition
        d.name = "added"; d.type = "INT"; d.isNullable = false; d.defaultMode = .value; d.defaultValue = "7"; state.updateColumn(id: id, definition: d)
        try await apply(state, to: o, baseline: before)
        #expect(try await write("SELECT id,added FROM schema_add_drop").rows == [["1","7"]])
        let after = try await s.load(object: o, configuration: config()); #expect(after.columns.map(\.name) == ["id","added"])
    }
    @Test func compositeIndexPrefixOrderVisibilityCommentUniqueAndDeletionRoundTrip() async throws {
        let o = object("schema_indexes"), s = MobileSchemaService(), before = try await s.load(object: o, configuration: config())
        #expect(before.indexes.first { $0.name == "functional_idx" }?.columns.first?.isExpression == true)
        var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes)
        let old = try #require(state.indexes.first { $0.definition.name == "old_idx" }); state.deleteIndex(id: old.id)
        let id = state.addIndex(); var d = try #require(state.indexes.first { $0.id == id }).definition
        d.name = "组合`索引"; d.kind = .unique; d.isVisible = false; d.comment = "索引注释"
        var a = WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition(name: "a"); a.prefixLength = "10"; a.isDescending = true
        d.columns = [a, .init(name: "b")]; state.updateIndex(id: id, definition: d)
        try await apply(state, to: o, baseline: before)
        let after = try await s.load(object: o, configuration: config()), index = try #require(after.indexes.first { $0.name == d.name })
        #expect(index.isUnique); #expect(!index.isVisible); #expect(index.comment == "索引注释")
        #expect(index.columns.map(\.name) == ["a","b"]); #expect(index.columns[0].prefixLength == 10); #expect(index.columns[0].direction == "D")
        #expect(after.indexes.contains { $0.name == "old_idx" } == false)
        #expect(after.indexes.first { $0.name == "functional_idx" } == before.indexes.first { $0.name == "functional_idx" })
    }
    @Test func staleMetadataPermissionsAndPendingAuthorizationDoNotAlterServer() async throws {
        let s = MobileSchemaService()
        for name in ["schema_stale", "schema_denied", "schema_authorization"] {
            let o = object(name), before = try await s.load(object: o, configuration: config())
            var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes)
            let item = try #require(state.columns.first); var d = item.definition; d.comment = "should not apply"; state.updateColumn(id: item.id, definition: d)
            if name == "schema_stale" { _ = try await write("ALTER TABLE schema_stale ADD COLUMN external_change INT") }
            do {
                if name == "schema_authorization" { try await apply(state, to: o, baseline: before, authorize: { throw MobileSchemaError.pending }) }
                else { try await apply(state, to: o, baseline: before, reader: name == "schema_denied") }
                Issue.record("must reject \(name)")
            } catch { }
            let after = try await s.load(object: o, configuration: config())
            #expect(after.columns.first?.comment != "should not apply")
        }
    }
    @Test func knownFailureAfterAcknowledgedDDLIsPartialAndMustNotReplay() async throws {
        let o = object("schema_partial"), s = MobileSchemaService(), before = try await s.load(object: o, configuration: config())
        var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes)
        for (name,type) in [("first_added","INT"),("second_invalid","NOT_A_MYSQL_TYPE")] {
            let id = state.addColumn(); var d = try #require(state.columns.first { $0.id == id }).definition; d.name = name; d.type = type; state.updateColumn(id: id, definition: d)
        }
        do { try await apply(state, to: o, baseline: before); Issue.record("must stop") }
        catch MobileSchemaError.partial(let completed, let total, _) { #expect(completed == 1); #expect(total == 2) }
        let after = try await s.load(object: o, configuration: config()); #expect(after.columns.map(\.name) == ["id","first_added"])
    }
    @Test func viewFieldReadingDoesNotRequireShowViewAndNeverOffersDDL() async throws {
        let o = MobileDatabaseObject(database: "querycraft_ios_table_actions", name: "action_view", kind: .view, comment: "")
        let s = MobileSchemaService(), result = try await s.load(object: o, configuration: config(reader: true))
        #expect(!result.columns.isEmpty); #expect(result.indexes.isEmpty); #expect(result.ddl.isEmpty)
    }
    @Test func cancellationBetweenStatementsRetainsConfirmedPrefix() async throws {
        let o = object("schema_cancel"), s = MobileSchemaService(), before = try await s.load(object: o, configuration: config())
        var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes)
        for name in ["first_added", "not_sent"] {
            let id = state.addColumn(); var d = try #require(state.columns.first { $0.id == id }).definition; d.name = name; d.type = "INT"; state.updateColumn(id: id, definition: d)
        }
        let gate = SchemaAuthorizationCounter()
        do { try await apply(state, to: o, baseline: before, authorize: { try await gate.authorize() }); Issue.record("must stop after first") }
        catch MobileSchemaError.partial(let completed, _, _) { #expect(completed == 1) }
        let after = try await s.load(object: o, configuration: config()); #expect(after.columns.map(\.name) == ["id","first_added"])
    }
    @Test func realDDLWithLostAcknowledgementRequiresVerification() async throws {
        let o = object("schema_unknown"), s = MobileSchemaService(), before = try await s.load(object: o, configuration: config())
        var state = WorkspaceDatabaseSchemaEditorState(); state.reset(columns: before.columns, indexes: before.indexes)
        let id = state.addColumn(); var d = try #require(state.columns.first { $0.id == id }).definition; d.name = "actually_added"; d.type = "INT"; state.updateColumn(id: id, definition: d)
        let faulty = MobileSchemaService(makeConnection: { SchemaLostAck(client: MariaDBClient(configuration: $0)) })
        do { try await apply(state, to: o, baseline: before, service: faulty); Issue.record("must be unknown") }
        catch MobileSchemaError.partial(let completed, _, _) { #expect(completed == 0) }
        let after = try await s.load(object: o, configuration: config()); #expect(after.columns.contains { $0.name == "actually_added" })
    }
}
private struct SchemaLostAck: MobileMutationConnection {
    let client: MariaDBClient
    func connect() async throws { try await client.connect() }
    func close() async { await client.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        let result = try await client.query(sql)
        if sql.hasPrefix("ALTER TABLE") { throw URLError(.networkConnectionLost) }
        return result
    }
}

private actor SchemaAuthorizationCounter {
    var calls = 0
    func authorize() throws { calls += 1; if calls == 3 { throw CancellationError() } }
}
