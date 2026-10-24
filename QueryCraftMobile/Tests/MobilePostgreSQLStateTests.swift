import Foundation
import Testing
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor struct MobilePostgreSQLStateTests {
    @Test func quotedIdentityAndProviderCapabilitiesPreservePhysicalParts() throws {
        for (schema, table) in [("public","ordinary"),("schema.dot","table.dot"),("schema\"quote","table.\"quote")] {
            let selection = WorkspaceDatabaseObjectSelection(databaseName: "db", objectName: WorkspaceDatabaseObject.postgreSQLName(schema: schema, table: table), kind: .table)
            #expect(selection.object.schemaName == schema); #expect(selection.object.nameWithinSchema == table)
            let sql = try WorkspaceTableActionStatement.make(action: .rename, selection: selection, databaseType: .postgresql, input: "new.\"name")
            #expect(sql.sql.contains(PostgreSQLDataMutation.TableIdentity(schema: schema, name: table).sql))
            #expect(sql.resultingSelection?.object.nameWithinSchema == "new.\"name"); #expect(sql.resultingSelection?.object.schemaName == schema)
        }
        #expect(MobileSchemaDialect(driver: .postgresql, serverVersion: 90600).descriptor.automaticValueStyle == nil)
        #expect(MobileSchemaDialect(driver: .postgresql, serverVersion: 110000).descriptor.generatedStorages == [.none])
        #expect(MobileSchemaDialect().descriptor == MySQLSchemaEditingProvider().descriptor)
    }
    @Test func sharedImporterUnknownCommitIsExplicitAndCannotReplayThroughNativeModel() async throws {
        let service = PGStateImportService(), object = MobileDatabaseObject(database: "db", name: "rows", kind: .table, comment: "", schemaName: "public")
        let model = MobileDataImportModel(object: object, configuration: .init(host: "localhost", port: 5432, username: "test", password: nil, database: "db", tlsMode: .disabled, driver: .postgresql), safetyLock: WorkspaceSafetyLock(), service: service)
        model.contextIsCurrent = { true }; model.allowsWrites = { true }
        let url = FileManager.default.temporaryDirectory.appending(path: "pg-state-\(UUID()).csv")
        try Data("id\n1\n2\n".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        model.select(url); await model.load()?.value; #expect(model.file?.rowCount == 2)
        await model.prepare()?.value; #expect(model.prepared != nil); #expect(model.run() == nil)
        model.safetyLock.disable(); await model.run()?.value
        #expect(model.needsVerification); #expect(model.blocksWrites); #expect(model.safetyLock.isEnabled); #expect(model.run() == nil)
        model.showing = false; model.showing = true; #expect(model.run() == nil)
        #expect(await service.runs == 1)
    }
    @Test func importOptionsAndFailedReloadCannotAcceptPreviousParsedSnapshot() async throws {
        let service = PGStateImportService(), object = MobileDatabaseObject(database: "db", name: "rows", kind: .table, comment: "", schemaName: "public")
        let model = MobileDataImportModel(object: object, configuration: .init(host: "localhost", port: 5432, username: "test", password: nil, database: "db", tlsMode: .disabled, driver: .postgresql), safetyLock: WorkspaceSafetyLock(), service: service)
        model.contextIsCurrent = { true }; model.allowsWrites = { true }
        let url = FileManager.default.temporaryDirectory.appending(path: "pg-state-\(UUID()).csv")
        try Data("id\n1\n".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        model.select(url); await model.load()?.value; await model.prepare()?.value; #expect(model.prepared != nil)
        model.options.emptyAsNull = true; #expect(model.prepared == nil); #expect(model.prepare() == nil); #expect(!model.hasCurrentPreview)
        await model.load()?.value; #expect(model.hasCurrentPreview)
        try Data("id\n\"open".utf8).write(to: url); await model.load()?.value
        #expect(model.file?.rowCount == 1); #expect(model.message != nil); #expect(!model.hasCurrentPreview); #expect(model.prepare() == nil)
        model.background(true); #expect(!model.canEdit); model.background(false); #expect(model.safetyLock.isEnabled)
    }
    @Test func sharedSchemaExecutorRollsBackAfterFailedPrefix() async throws {
        let trace = PGSchemaTrace()
        let plan = WorkspaceDatabaseSchemaExecutionPlan(dialectIdentifier: "postgresql", source: .changes(.init(selection: .init(databaseName: "db", objectName: "public.rows", kind: .table), columns: [], indexes: [])), transactionMode: .transaction,
            statements: [.init(sql: "first", previewTokens: [], kind: .ddl(.alter)),.init(sql: "fail", previewTokens: [], kind: .ddl(.alter)),.init(sql: "never", previewTokens: [], kind: .ddl(.alter))])
        do { try await PostgreSQLSchemaExecutor.apply(plan, execute: { try await trace.execute($0) }); Issue.record("failure accepted") } catch {}
        #expect(await trace.statements == ["BEGIN","first","fail","ROLLBACK"])
    }
}
private actor PGStateImportService: MobileDataImportServicing {
    private(set) var runs = 0
    func schema(object: MobileDatabaseObject, configuration: MobileSQLConfiguration) async throws -> WorkspaceDataImportSchema {
        .init(columns: [.init(name: "id", type: "bigint", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "")], tableParts: ["public","rows"], supportsRollback: true)
    }
    func run(object: MobileDatabaseObject, configuration: MobileSQLConfiguration, plan: WorkspaceDataImportPlan, authorize: @escaping WorkspaceDataImporter.Authorize, progress: @escaping @Sendable (Int) async -> Void) async -> WorkspaceDataImportOutcome {
        runs += 1
        do { try await authorize() } catch { return .init(status: .failed, committedRows: 0, message: error.localizedDescription) }
        return .init(status: .uncertain, committedRows: nil, message: "lost commit acknowledgement")
    }
}
private actor PGSchemaTrace {
    var statements: [String] = []
    func execute(_ sql: String) throws { statements.append(sql); if sql == "fail" { throw URLError(.cannotParseResponse) } }
}

@MainActor struct MobilePostgreSQLImportEngineTests {
    @Test func lostCommitAndAuthorizationFailureUseSharedEngineFences() async throws {
        let column = WorkspaceDatabaseColumn(name: "id", type: "bigint", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "")
        let schema = WorkspaceDataImportSchema(columns: [column], tableParts: ["public","rows"], supportsRollback: true)
        let file = try WorkspaceDataImportFile(columns: ["id"], rows: [["1"],["2"]])
        let plan = WorkspaceDataImportPlan(file: file, schema: schema, mapping: ["id"], batchSize: 1, dialect: .postgresql)
        let lost = PGImportEngineConnection(schema: schema)
        let result = await WorkspaceDataImporter().run(connection: lost, plan: plan, authorize: {}, progress: { _ in })
        #expect(result.status == .uncertain); #expect(result.committedRows == nil)
        #expect(await lost.statements.filter { $0 == "COMMIT" }.count == 1)
        #expect(!(await lost.statements.contains("ROLLBACK")))
        let cancelled = PGImportEngineConnection(schema: schema)
        let gate = PGImportAuthorization()
        let stop = await WorkspaceDataImporter().run(connection: cancelled, plan: plan, authorize: {
            if !gate.allowed { throw CancellationError() }
        }, progress: { _ in await gate.stop() })
        #expect(stop.status == .cancelled); #expect(stop.committedRows == 0)
        #expect(await cancelled.statements.filter { $0.hasPrefix("INSERT") }.count == 1)
        #expect(await cancelled.statements.last == "ROLLBACK")
    }
}
@MainActor private final class PGImportAuthorization { var allowed = true; func stop() { allowed = false } }
private actor PGImportEngineConnection: WorkspaceDataImportConnection {
    let snapshot: WorkspaceDataImportSchema
    var statements: [String] = []
    init(schema: WorkspaceDataImportSchema) { snapshot = schema }
    func connect() {}
    func schema() -> WorkspaceDataImportSchema { snapshot }
    func prepare() {}
    func execute(_ sql: String, kind: SQLStatementKind) throws -> Int {
        statements.append(sql); if sql == "COMMIT" { throw URLError(.networkConnectionLost) }
        return sql.hasPrefix("INSERT") ? 1 : 0
    }
    func close() {}
}
