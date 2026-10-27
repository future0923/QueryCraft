import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil))
struct MobilePostgreSQLParityTests {
    static func configuration(user: String = "postgres") throws -> MobileSQLConfiguration {
        .init(host: MobileFixtureEndpoint.host, port: try #require(ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"].flatMap(Int.init)),
              username: user, password: "querycraft-proof-pg", database: "querycraft_ios_pg", tlsMode: .disabled, driver: .postgresql)
    }
    @discardableResult static func query(_ sql: String) async throws -> PostgreSQLCQueryResult {
        let client = LibPQClient(configuration: try configuration().postgreSQL)
        do { try await client.connect(); let result = try await client.query(sql); await client.close(); return result }
        catch { await client.close(); throw error }
    }
    static func withSchema(_ body: @MainActor (String) async throws -> Void) async throws {
        let schema = "parity.雪\"" + UUID().uuidString.prefix(8)
        let quoted = PostgreSQLCatalog.identifier(schema)
        try await query("CREATE SCHEMA " + quoted)
        do { try await body(schema); try await query("DROP SCHEMA " + quoted + " CASCADE") }
        catch { _ = try? await query("DROP SCHEMA " + quoted + " CASCADE"); throw error }
    }
    static func object(_ schema: String, _ name: String = "table.with.dot") -> MobileDatabaseObject {
        .init(database: "querycraft_ios_pg", name: name, kind: .table, comment: "", schemaName: schema)
    }
    static func table(_ schema: String, _ name: String = "table.with.dot") -> String { PostgreSQLDataMutation.TableIdentity(schema: schema, name: name).sql }
    private func model(_ sql: String, schema: String) async throws -> MobileQueryModel {
        let config = try Self.configuration(), model = MobileQueryModel(executor: MobilePostgreSQLExecutor(), metadataService: MobilePostgreSQLService(), mutationService: MobilePostgreSQLMutationService())
        model.driver = .postgresql; model.host = config.host; model.port = String(config.port); model.username = config.username; model.password = config.password ?? ""
        model.database = config.database ?? ""; model.schemaName = schema; model.tlsMode = .disabled; model.sql = sql
        await model.execute()?.value
        #expect(model.errorMessage == nil, Comment(rawValue: model.errorMessage ?? ""))
        return model
    }
    @Test func queryResultAliasesLargeKeyExpressionsAndDeleteKeepPhysicalTarget() async throws {
        try await Self.withSchema { schema in
            let table = Self.table(schema)
            try await Self.query("CREATE TABLE " + table + " (id BIGINT PRIMARY KEY,name TEXT NOT NULL DEFAULT 'default',amount INTEGER CHECK(amount>=0))")
            try await Self.query("INSERT INTO " + table + " VALUES (9007199254740993,'original',1),(2,'two',2)")
            let model = try await model("SELECT id AS row_key,name AS label,name AS again,name || '!' AS expression FROM " + table + " ORDER BY id DESC", schema: schema)
            let changes = try #require(model.editing, Comment(rawValue: model.editingMessage ?? "missing")), page = try #require(model.editingPage)
            let request = try changes.request(page: page, row: 0, column: 1)
            #expect(request.primaryKey.first?.value == .text("9007199254740993")); #expect(changes.object.schemaName == schema)
            #expect(throws: WorkspaceDatabaseDataCellEditError.metadataUnavailable) { try changes.request(page: page, row: 0, column: 3) }
            try changes.stage(request, text: "O'Reilly\\雪", mode: .value)
            #expect(model.displayData.cell(row: 0, column: 2) == .text("O'Reilly\\雪"))
            model.sql = "SELECT 999"; changes.safetyLock.disable(); await changes.submit()?.value; await model.waitForCachePatch()
            #expect(changes.message == nil, Comment(rawValue: changes.message ?? "")); #expect(model.sql == "SELECT 999")
            #expect(model.result?.rows[0][3] == "original!")
            #expect(try await Self.query("SELECT name FROM " + table + " WHERE id=9007199254740993").rows[0][0] == "O'Reilly\\雪")
            try changes.toggleDelete(page: #require(model.editingPage), row: 1); await changes.submit()?.value; await model.waitForCachePatch()
            #expect(changes.message == nil); #expect(model.result?.rows.count == 1)
            _ = await model.disconnectSQL()?.value
        }
    }
    @Test func queryNoKeyExpressionNamedKeyJoinViewAndEmptyRemainTruthful() async throws {
        try await Self.withSchema { schema in
            let table = Self.table(schema)
            try await Self.query("CREATE TABLE " + table + " (id INTEGER PRIMARY KEY,name TEXT)")
            try await Self.query("INSERT INTO " + table + " VALUES (1,'one')")
            try await Self.query("CREATE VIEW " + Self.table(schema,"view") + " AS SELECT * FROM " + table)
            for sql in ["SELECT a.id,a.name,b.name FROM " + table + " a JOIN " + table + " b ON a.id=b.id", "SELECT * FROM " + Self.table(schema,"view")] {
                let model = try await model(sql, schema: schema); #expect(model.editing == nil); _ = await model.disconnectSQL()?.value
            }
            let missing = try await model("SELECT 123 AS id,name FROM " + table, schema: schema)
            #expect(throws: WorkspaceDatabaseDataCellEditError.primaryKeyValueUnavailable("id")) { try #require(missing.editing).request(page: #require(missing.editingPage), row: 0, column: 1) }
            _ = await missing.disconnectSQL()?.value
            let empty = try await model("SELECT * FROM " + table + " WHERE false", schema: schema)
            #expect(empty.result?.rows.isEmpty == true); #expect(empty.editing != nil); _ = await empty.disconnectSQL()?.value
        }
    }
    @Test func sharedSchemaPlanAddsChangesAndIndexesTransactionally() async throws {
        try await Self.withSchema { schema in
            let object = Self.object(schema), service = MobilePostgreSQLSchemaService()
            try await Self.query("CREATE TABLE " + Self.table(schema) + " (id BIGINT PRIMARY KEY,name TEXT DEFAULT 'old')")
            let baseline = try await service.load(object: object, configuration: Self.configuration())
            let draft = MobileSchemaDraft(object: object, driver: .postgresql); draft.receive(baseline)
            #expect(draft.dialect.descriptor.automaticValueStyle == .identity)
            let existing = try #require(draft.state.columns.first { $0.definition.name == "name" })
            var value = existing.definition; value.name = "new.name"; value.comment = "注释雪"; value.defaultMode = .expression; value.defaultValue = "upper('new')"
            draft.updateColumn(existing.id, definition: value, primary: false)
            draft.section = .columns; let added = draft.add(); var extra = try #require(draft.state.columns.first { $0.id == added }).definition
            extra.name = "payload"; extra.type = "jsonb"; draft.updateColumn(added, definition: extra, primary: false)
            draft.section = .indexes; let indexID = draft.add(); var index = try #require(draft.state.indexes.first { $0.id == indexID }).definition
            index.name = "name.index"; index.method = "btree"; index.comment = "索引注释"; index.columns = [.init(name: "new.name", sourceColumnID: existing.id)]
            draft.updateIndex(indexID, definition: index)
            try await service.apply(object: object, baseline: baseline, plan: draft.plan, configuration: Self.configuration(), authorize: {})
            let fresh = try await service.load(object: object, configuration: Self.configuration())
            #expect(fresh.columns.contains { $0.name == "new.name" && $0.comment == "注释雪" }); #expect(fresh.columns.contains { $0.name == "payload" && $0.type == "jsonb" })
            #expect(fresh.indexes.contains { $0.name == "name.index" && $0.comment == "索引注释" })
            do { try await service.apply(object: object, baseline: baseline, plan: draft.plan, configuration: Self.configuration(), authorize: {}); Issue.record("stale plan executed") } catch { #expect(error is MobileSchemaError) }
        }
    }
    @Test func failedSchemaBatchRollsBackAndNewTableSupportsIdentityGeneratedIndex() async throws {
        try await Self.withSchema { schema in
            let object = Self.object(schema), service = MobilePostgreSQLSchemaService()
            try await Self.query("CREATE TABLE " + Self.table(schema) + " (id BIGINT PRIMARY KEY,name TEXT)")
            let baseline = try await service.load(object: object, configuration: Self.configuration())
            let draft = MobileSchemaDraft(object: object, driver: .postgresql); draft.receive(baseline)
            let existing = try #require(draft.state.columns.first { $0.definition.name == "name" }); var changed = existing.definition; changed.name = "renamed"
            draft.updateColumn(existing.id, definition: changed, primary: false)
            let added = draft.add(); var bad = try #require(draft.state.columns.first { $0.id == added }).definition; bad.name = "bad"; bad.type = "no_such_type"; draft.updateColumn(added, definition: bad, primary: false)
            do { try await service.apply(object: object, baseline: baseline, plan: draft.plan, configuration: Self.configuration(), authorize: {}); Issue.record("invalid type accepted") } catch {}
            #expect(try await service.load(object: object, configuration: Self.configuration()).columns.map(\.name) == ["id","name"])
            let new = MobileNewTableDraft(database: object.database, schema: schema, driver: .postgresql); new.serverVersion = 170000; new.definition.updateDescriptor(new.dialect.descriptor); new.definition.tableName = "new.table"
            let first = try #require(new.definition.editor.columns.first); var id = first.definition; id.name = "id"; id.type = "bigint"; id.isAutoIncrement = true; id.isNullable = false; id.defaultMode = .none
            new.definition.editor.updateColumn(id: first.id, definition: id); new.definition.editor.setPrimaryKey(columnID: first.id, isEnabled: true)
            let nameID = new.definition.editor.addColumn(defaultType: "text"); var nameDefinition = try #require(new.definition.editor.columns.first { $0.id == nameID }).definition
            nameDefinition.name = "label"; nameDefinition.defaultMode = .value; nameDefinition.defaultValue = "generated base"; nameDefinition.comment = "column comment"
            new.definition.editor.updateColumn(id: nameID, definition: nameDefinition)
            let computedID = new.definition.editor.addColumn(defaultType: "text"); var computed = try #require(new.definition.editor.columns.first { $0.id == computedID }).definition
            computed.name = "computed"; computed.generatedStorage = .stored; computed.generationExpression = "label || '!'"; new.definition.editor.updateColumn(id: computedID, definition: computed)
            let indexID = new.definition.editor.addIndex(); var index = try #require(new.definition.editor.indexes.first { $0.id == indexID }).definition
            index.name = "label.index"; index.method = "btree"; index.comment = "index comment"; index.columns = [.init(name: "label", sourceColumnID: nameID)]
            new.definition.editor.updateIndex(id: indexID, definition: index)
            let result = try await MobilePostgreSQLNewTableService().create(plan: new.plan, configuration: Self.configuration(), authorize: {})
            #expect(result.object.schemaName == schema); #expect(result.object.nameWithinSchema == "new.table")
            try await Self.query("INSERT INTO " + Self.table(schema,"new.table") + " DEFAULT VALUES")
            #expect(try await Self.query("SELECT id,computed FROM " + Self.table(schema,"new.table")).rows == [["1","generated base!"]])
        }
    }
    @Test func tableActionsPreserveSchemaRenameClearSequenceAndDrop() async throws {
        try await Self.withSchema { schema in
            var object = Self.object(schema); let service = MobilePostgreSQLTableActionService()
            try await Self.query("CREATE TABLE " + Self.table(schema) + " (id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,name TEXT)")
            #expect(try await service.inspect(object: object, configuration: Self.configuration()).hasAutoIncrement)
            _ = try await service.perform(action: .setAutoIncrement, object: object, input: "99", configuration: Self.configuration(), authorize: {})
            try await Self.query("INSERT INTO " + Self.table(schema) + "(name) VALUES('one')")
            #expect(try await Self.query("SELECT id FROM " + Self.table(schema)).rows == [["99"]])
            _ = try await service.perform(action: .truncate, object: object, input: "", configuration: Self.configuration(), authorize: {})
            try await Self.query("INSERT INTO " + Self.table(schema) + "(name) VALUES('two')")
            #expect(try await Self.query("SELECT id FROM " + Self.table(schema)).rows == [["100"]])
            let renamed = try await service.perform(action: .rename, object: object, input: "new.雪", configuration: Self.configuration(), authorize: {})
            #expect(renamed.resultingSelection?.object.nameWithinSchema == "new.雪")
            object = Self.object(schema,"new.雪")
            _ = try await service.perform(action: .clear, object: object, input: "", configuration: Self.configuration(), authorize: {})
            #expect(try await Self.query("SELECT count(*) FROM " + Self.table(schema,"new.雪")).rows == [["0"]])
            _ = try await service.perform(action: .drop, object: object, input: "", configuration: Self.configuration(), authorize: {})
        }
    }
    @Test func realFileImportMapsFullRowsNullIdentityAndRollback() async throws {
        try await Self.withSchema { schema in
            let object = Self.object(schema), table = Self.table(schema), service = MobilePostgreSQLImportService(), config = try Self.configuration()
            try await Self.query("CREATE TABLE " + table + "(id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,name TEXT NOT NULL,amount INTEGER CHECK(amount>=0), nullable TEXT,computed TEXT GENERATED ALWAYS AS(name || '!') STORED)")
            let metadata = try await service.schema(object: object, configuration: config)
            #expect(!metadata.writableColumns.contains { $0.name == "computed" })
            let file = try WorkspaceDelimitedImporter.read("id,name,amount,nullable\n9007199254740993,\"雪,\\name\",1,NULL\n2,\"NULL\",2,\"\"\n", options: .init())
            let plan = WorkspaceDataImportPlan(file: file, schema: metadata, mapping: metadata.automaticMapping(file.columns), batchSize: 1, dialect: .postgresql)
            let result = await service.run(object: object, configuration: config, plan: plan, authorize: {}, progress: { _ in })
            #expect(result.status == .completed); #expect(result.committedRows == 2)
            #expect(try await Self.query("SELECT id,name,nullable,computed FROM " + table + " ORDER BY id DESC").rows == [["9007199254740993","雪,\\name",nil,"雪,\\name!"],["2","NULL","","NULL!"]])
            let bad = try WorkspaceDataImportFile(columns: ["id","name","amount"], rows: [["3","prefix","3"],["4","failure","-1"]])
            let rollback = await service.run(object: object, configuration: config, plan: .init(file: bad, schema: metadata, mapping: metadata.automaticMapping(bad.columns), batchSize: 1, dialect: .postgresql), authorize: {}, progress: { _ in })
            #expect(rollback.status == .failed); #expect(rollback.committedRows == 0)
            #expect(try await Self.query("SELECT count(*) FROM " + table).rows == [["2"]])
        }
    }
    @Test func lostSchemaCommitAndBackgroundCancellationKeepActualServerOutcome() async throws {
        try await Self.withSchema { schema in
            let object = Self.object(schema), config = try Self.configuration()
            try await Self.query("CREATE TABLE " + Self.table(schema) + " (id INTEGER PRIMARY KEY,name TEXT)")
            let baseline = try await MobilePostgreSQLSchemaService().load(object: object, configuration: config)
            let lost = PGParityFaultConnection(configuration: config, hold: false)
            let controller = MobileSchemaController(configuration: config, safetyLock: WorkspaceSafetyLock(), service: MobilePostgreSQLSchemaService(makeConnection: { _ in lost }))
            let context = UUID(); controller.contextID = { context }; controller.isCurrent = { _ in true }; controller.allowsWrites = { true }; controller.hasPendingData = { _ in false }
            let draft = controller.draft(for: object); draft.receive(baseline)
            let field = try #require(draft.state.columns.last); var definition = field.definition; definition.comment = "committed before lost receipt"; draft.updateColumn(field.id, definition: definition, primary: false)
            controller.safetyLock.disable(); await controller.submit(draft)?.value
            #expect(draft.needsVerification); #expect(controller.submit(draft) == nil)
            #expect(await lost.statements.filter { $0 == "COMMIT" }.count == 1)
            let actual = try await MobilePostgreSQLSchemaService().load(object: object, configuration: config)
            #expect(actual.columns.last?.comment == "committed before lost receipt")
            let held = PGParityFaultConnection(configuration: config, hold: true)
            let stopped = MobileSchemaController(configuration: config, safetyLock: WorkspaceSafetyLock(), service: MobilePostgreSQLSchemaService(makeConnection: { _ in held }))
            stopped.contextID = { context }; stopped.isCurrent = { _ in true }; stopped.allowsWrites = { true }; stopped.hasPendingData = { _ in false }
            let next = stopped.draft(for: object); next.receive(actual)
            let original = try #require(next.state.columns.last); var rename = original.definition; rename.name = "must_rollback"; next.updateColumn(original.id, definition: rename, primary: false)
            stopped.safetyLock.disable(); let task = try #require(stopped.submit(next)); #expect(await held.waitForGate())
            stopped.cancel(); await held.release(); await task.value
            #expect(!next.needsVerification); #expect(next.hasChanges)
            #expect(await held.statements.contains("ROLLBACK")); #expect(!(await held.statements.contains("COMMIT")))
            #expect(try await MobilePostgreSQLSchemaService().load(object: object, configuration: config).columns.last?.name == "name")
        }
    }

    @Test func originalCopyTransportAndDiskBackedImportPreserveFullValues() async throws {
        try await Self.withSchema { schema in
            let object = Self.object(schema), table = Self.table(schema), config = try Self.configuration()
            try await Self.query("CREATE TABLE " + table + " (id BIGINT PRIMARY KEY,name TEXT NOT NULL)")
            let client = LibPQClient(configuration: config.postgreSQL)
            try await client.connect(); _ = try await client.query("BEGIN")
            let stream = WorkspaceNativeBulkStream()
            let producer = Task { do { try await stream.send(Data("9007199254740993\tCOPY雪\n".utf8)); stream.finish() } catch { stream.fail(error); throw error } }
            let copied = try await client.copyFrom(sql: "COPY " + table + " (id,name) FROM STDIN WITH (FORMAT text)", stream: stream)
            try await producer.value; #expect(copied == 1)
            #expect(try await client.query("SELECT id,name FROM " + table).rows == [["9007199254740993","COPY雪"]])
            _ = try await client.query("ROLLBACK"); await client.close()
            let url = FileManager.default.temporaryDirectory.appending(path: "pg-large-\(UUID()).csv")
            defer { try? FileManager.default.removeItem(at: url) }
            let payload = String(repeating: "雪", count: 520)
            try ("id,name\n" + (0..<3001).map { "\($0),\(payload)\n" }.joined()).write(to: url, atomically: false, encoding: .utf8)
            let file = try await WorkspaceDataImportReader().read(url: url, options: .init())
            #expect(file.isDiskBacked); #expect(file.rowCount == 3001)
            let service = MobilePostgreSQLImportService(), metadata = try await service.schema(object: object, configuration: config)
            let result = await service.run(object: object, configuration: config, plan: .init(file: file, schema: metadata, mapping: ["id","name"], batchSize: 500, dialect: .postgresql), authorize: {}, progress: { _ in })
            #expect(result.status == .completed); #expect(result.committedRows == 3001)
            #expect(try await Self.query("SELECT count(*),min(length(name)),max(length(name)) FROM " + table).rows == [["3001","520","520"]])
            let lost = PGParityFaultConnection(configuration: config, hold: false)
            let more = try WorkspaceDataImportFile(columns: ["id","name"], rows: [["99999","lost receipt"]])
            let uncertain = await MobilePostgreSQLImportService(makeConnection: { _ in lost }).run(object: object, configuration: config, plan: .init(file: more, schema: metadata, mapping: ["id","name"], batchSize: 1, dialect: .postgresql), authorize: {}, progress: { _ in })
            #expect(uncertain.status == .uncertain); #expect(uncertain.committedRows == nil)
            #expect(try await Self.query("SELECT name FROM " + table + " WHERE id=99999").rows == [["lost receipt"]])
            #expect(await lost.statements.filter { $0 == "COMMIT" }.count == 1)
        }
    }

    @Test func cachedPagesRemainEditableAndWholeExportKeepsOtherPagesAfterCommit() async throws {
        try await Self.withSchema { schema in
            let table = Self.table(schema)
            try await Self.query("CREATE TABLE " + table + " (id INTEGER PRIMARY KEY,name TEXT)")
            try await Self.query("INSERT INTO " + table + " SELECT n,'row-' || n FROM generate_series(1,1501) n")
            let model = try await model("SELECT id,name,name || '!' AS expression FROM " + table + " ORDER BY id", schema: schema)
            #expect(model.cachedRowCount == 1501); #expect(model.editing != nil)
            let oldChanges = try #require(model.editing), oldPage = try #require(model.editingPage)
            await model.pageCache(1)?.value; #expect(model.cacheOffset == 500)
            #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try oldChanges.request(page: oldPage, row: 0, column: 1) }
            let changes = try #require(model.editing), page = try #require(model.editingPage)
            try changes.stage(changes.request(page: page, row: 0, column: 1), text: "saved in cache", mode: .value)
            try changes.toggleDelete(page: page, row: 1)
            changes.safetyLock.disable(); await changes.submit()?.value; await model.waitForCachePatch()
            #expect(changes.message == nil); #expect(model.cachedRowCount == 1500); #expect(model.cacheOffset == 500)
            #expect(model.result?.rows.first == ["501","saved in cache","row-501!"])
            #expect(model.result?.rows[1][0] == "503")
            let snapshot = try #require(model.queryExportSnapshot)
            var options = WorkspaceDataExportOptions(); options.scope = .allTableRows; options.format = .csv
            let url = FileManager.default.temporaryDirectory.appending(path: "pg-edited-cache-\(UUID()).csv"); defer { try? FileManager.default.removeItem(at: url) }
            let count = try await WorkspaceDataExporter().export(snapshot.request(options: options), to: url) { _ in }
            #expect(count == 1500)
            let exported = try WorkspaceDelimitedImporter.read(String(contentsOf: url, encoding: .utf8), options: .init())
            #expect(exported.rowCount == 1500); #expect(try exported.rows[500] == ["501","saved in cache","row-501!"])
            await model.pageCache(-1)?.value; #expect(model.cacheOffset == 0); #expect(model.result?.rows.first?[0] == "1")
            await model.pageCache(1)?.value; #expect(model.result?.rows.first?[1] == "saved in cache"); #expect(model.editing != nil)
            await model.disconnectSQL()?.value
        }
    }

    @Test func zeroColumnNewTableUsesMacPlanAndCanAddFirstColumn() async throws {
        try await Self.withSchema { schema in
            let new = MobileNewTableDraft(database: "querycraft_ios_pg", schema: schema, driver: .postgresql)
            new.definition.tableName = "zero"
            for column in new.definition.editor.columns { _ = new.definition.editor.deleteColumn(id: column.id) }
            #expect(new.isValid)
            _ = try await MobilePostgreSQLNewTableService().create(plan: new.plan, configuration: Self.configuration(), authorize: {})
            let object = Self.object(schema,"zero"), service = MobilePostgreSQLSchemaService(), config = try Self.configuration()
            let baseline = try await service.load(object: object, configuration: config); #expect(baseline.columns.isEmpty)
            #expect(try await MobilePostgreSQLService().columns(configuration: config, object: object).isEmpty)
            let draft = MobileSchemaDraft(object: object, driver: .postgresql); draft.receive(baseline)
            let id = draft.add(); var field = try #require(draft.state.columns.first { $0.id == id }).definition; field.name = "first"; draft.updateColumn(id, definition: field, primary: false)
            try await service.apply(object: object, baseline: baseline, plan: draft.plan, configuration: config, authorize: {})
            #expect(try await service.load(object: object, configuration: config).columns.map(\.name) == ["first"])
        }
    }

}

private actor PGParityFaultConnection: MobileMutationConnection {
    let connection: MobilePostgreSQLMutationConnection
    let hold: Bool
    var statements: [String] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var waiting = false
    init(configuration: MobileSQLConfiguration, hold: Bool) { connection = .init(client: LibPQClient(configuration: configuration.postgreSQL)); self.hold = hold }
    func connect() async throws { try await connection.connect() }
    func close() async { await connection.close() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        statements.append(sql)
        let result = try await connection.query(sql, bindings: bindings)
        if sql == "COMMIT", !hold { throw URLError(.networkConnectionLost) }
        if sql.hasPrefix("ALTER TABLE"), hold { waiting = true; await withCheckedContinuation { waiter = $0 }; try Task.checkCancellation() }
        return result
    }
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }; return waiting
    }
    func release() { waiter?.resume(); waiter = nil; waiting = false }
}
