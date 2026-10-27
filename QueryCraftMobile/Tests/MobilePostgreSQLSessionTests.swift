import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"] != nil))
struct MobilePostgreSQLSessionTests {
    func config(reader: Bool = false) throws -> MobileSQLConfiguration {
        .init(host: MobileFixtureEndpoint.host, port: try #require(ProcessInfo.processInfo.environment["PROOF_POSTGRES_PORT"].flatMap(Int.init)),
              username: reader ? "proof_reader" : "proof_writer", password: reader ? "querycraft-proof-pg" : "querycraft-proof-pg-writer",
              database: "querycraft_ios_pg", tlsMode: .disabled, driver: .postgresql, schemaName: "mobile_session")
    }
    func model(reader: Bool = false, session: MobileSQLSession? = nil) throws -> MobileQueryModel {
        let config = try config(reader: reader), model = MobileQueryModel(executor: MobilePostgreSQLExecutor(), metadataService: MobilePostgreSQLService(), session: session)
        model.driver = .postgresql; model.host = config.host; model.port = String(config.port); model.username = config.username; model.password = config.password ?? ""
        model.database = config.database ?? ""; model.schemaName = config.schemaName; model.tlsMode = config.tlsMode; model.exportDialect = .postgresql
        model.allowsDataMutation = { false }
        return model
    }
    @discardableResult func query(_ sql: String) async throws -> PostgreSQLCQueryResult {
        let client = LibPQClient(configuration: try config().postgreSQL)
        do { try await client.connect(); let result = try await client.query(sql); await client.close(); return result }
        catch { await client.close(); throw error }
    }
    func reset() async throws { try await query("DELETE FROM mobile_session.records") }
    func run(_ sql: String, on model: MobileQueryModel, confirm: Bool = false) async {
        model.sql = sql; model.executionInput.selection = .init(location: 0, length: 0)
        await model.executeAll()?.value
        if confirm { await model.confirmSQL()?.value }
    }
    @Test func confirmationReturningAndRefreshNeverReplayWrites() async throws {
        try await reset(); let model = try model()
        await run("INSERT INTO records(id,name) VALUES (318987599031067570,'雪') RETURNING id,name", on: model)
        #expect(model.sqlConfirmation?.requiresUnlock == true)
        #expect(try await query("SELECT count(*) FROM mobile_session.records").rows == [["0"]])
        await model.confirmSQL()?.value
        #expect(model.errorMessage == nil); #expect(model.result?.rows == [["318987599031067570", "雪"]])
        #expect(model.result?.affectedRows == 1)
        #expect(model.preview?.workspaceColumns[1].origin?.schemaName == "mobile_session")
        #expect(model.columnDetails[1].contains("session name"))
        await model.refresh()?.value; #expect(model.errorMessage?.contains("不会重放") == true)
        await run("UPDATE records SET name='changed' WHERE id=318987599031067570", on: model)
        #expect(model.sqlConfirmation != nil); #expect(model.sqlConfirmation?.requiresUnlock == false)
        await model.confirmSQL()?.value; #expect(model.errorMessage == nil)
        #expect(model.result?.affectedRows == 1); #expect(!model.status.contains("插入 ID"))
        await model.disconnectSQL()?.value
    }
    @Test func sameConnectionTransactionsSavepointsAndCommitUseServerState() async throws {
        try await reset(); let model = try model()
        await model.transaction(.begin)?.value
        #expect(model.transactionState == .inTransaction); #expect(model.errorMessage == nil)
        await run("SELECT pg_backend_pid()", on: model); let pid = model.result?.rows
        await run("INSERT INTO records(id) VALUES(1)", on: model, confirm: true)
        #expect(model.errorMessage == nil)
        #expect(try await query("SELECT count(*) FROM mobile_session.records").rows == [["0"]])
        await run("SAVEPOINT qc; INSERT INTO records(id) VALUES(2); ROLLBACK TO SAVEPOINT qc; SELECT id FROM records; SELECT pg_backend_pid()", on: model)
        #expect(model.errorMessage == nil); #expect(model.statementResults.count == 5)
        #expect(model.selectResult(model.statementResults[3].id)); #expect(model.result?.rows == [["1"]])
        #expect(model.selectResult(model.statementResults[4].id)); #expect(model.result?.rows == pid)
        model.schemaName = "public"; #expect(model.schemaName == "mobile_session")
        let port = model.port; model.port = "1"; #expect(model.port == port)
        model.safetyLock.enable(); await model.transaction(.commit)?.value
        #expect(model.errorMessage == nil); #expect(model.transactionState == .autoCommit)
        #expect(try await query("SELECT id FROM mobile_session.records").rows == [["1"]])
        await model.transaction(.begin)?.value
        await run("INSERT INTO records(id) VALUES(3)", on: model, confirm: true)
        await model.transaction(.rollback)?.value
        #expect(model.errorMessage == nil)
        #expect(try await query("SELECT id FROM mobile_session.records").rows == [["1"]])
        await model.disconnectSQL()?.value
    }
    @Test func transactionLocalDDLAndErrorDisconnectRollBackWithoutRunningSuffix() async throws {
        try await reset(); let model = try model()
        await model.transaction(.begin)?.value
        await run("CREATE TEMP TABLE qc_session_temp(id INTEGER PRIMARY KEY, note TEXT)", on: model, confirm: true)
        #expect(model.errorMessage == nil); #expect(model.transactionState == .inTransaction)
        await run("INSERT INTO qc_session_temp VALUES(1,'local'); SELECT note AS alias FROM qc_session_temp", on: model)
        #expect(model.errorMessage == nil); #expect(model.selectResult(model.statementResults[1].id))
        #expect(model.preview?.workspaceColumns[0].origin?.tableName == "qc_session_temp")
        #expect(model.preview?.workspaceColumns[0].type == "text")
        await run("INSERT INTO records(id) VALUES(1); SELECT * FROM qc_missing; INSERT INTO records(id) VALUES(2)", on: model)
        #expect(model.statementResults.map(\.phase) == [.completed, .failed, .skipped])
        #expect(model.transactionState == .disconnected); #expect(!model.writeOutcomeUncertain)
        #expect(try await query("SELECT count(*) FROM mobile_session.records").rows == [["0"]])
        await model.disconnectSQL()?.value
    }
    @Test func diskCachePreservesSchemaCommentsPagingAndExportBeyondPreview() async throws {
        let model = try model()
        await run("SELECT n, '雪'::text AS label, NULL::text AS absent FROM generate_series(1,12000) n", on: model)
        #expect(model.errorMessage == nil); #expect(model.cachedRowCount == 12000); #expect(model.result?.rows.count == 500)
        let cache = try #require(model.statementResults.first?.cache); #expect(cache.store.isDiskBacked)
        await model.pageCache(1)?.value; #expect(model.cacheOffset == 500); #expect(model.result?.rows.first == ["501", "雪", nil])
        #expect(model.preview?.workspaceColumns.first?.type == "integer")
        let snapshot = try #require(model.queryExportSnapshot)
        var options = WorkspaceDataExportOptions(); options.scope = .allTableRows
        let request = try snapshot.request(options: options)
        var count = 0
        while let batch = try await request.source.nextBatch() { count += batch.count }
        await request.source.finish(); #expect(count == 12000)
        try await reset(); try await query("INSERT INTO mobile_session.records VALUES(1,'name',10)")
        await run("SELECT r.name AS alias, length(r.name) AS name FROM records r CROSS JOIN generate_series(1,1001) n", on: model)
        #expect(model.errorMessage == nil); #expect(model.columnDetails[0].contains("session name")); #expect(!model.columnDetails[1].contains("session name"))
        await model.pageCache(1)?.value
        #expect(model.preview?.workspaceColumns[0].origin?.schemaName == "mobile_session")
        #expect(model.columnDetails[0].contains("session name")); #expect(model.preview?.workspaceColumns[1].origin == nil)
        await run("SELECT name AS alias FROM records WHERE false", on: model)
        #expect(model.result?.rows.isEmpty == true); #expect(model.preview?.workspaceColumns.first?.type == "text")
        #expect(model.columnDetails.first?.contains("session name") == true)
        await model.disconnectSQL()?.value
    }
    @Test func sessionEscapeModeDoesNotCorruptPhysicalMetadataOrLiterals() async throws {
        let model = try model()
        await run("CREATE TEMP TABLE \"qc\\table\"(name TEXT); COMMENT ON COLUMN \"qc\\table\".name IS 'slash comment'; INSERT INTO \"qc\\table\" VALUES ('value'); SET standard_conforming_strings TO off", on: model, confirm: true)
        #expect(model.errorMessage == nil)
        await run("SELECT name AS alias FROM \"qc\\table\"", on: model)
        #expect(model.errorMessage == nil); #expect(model.columnDetails.first?.contains("slash comment") == true)
        #expect(model.preview?.workspaceColumns.first?.origin?.tableName == "qc\\table")
        let value = "quote'\\雪"
        await run("SELECT " + PostgreSQLCatalog.literal(value) + " AS value", on: model)
        #expect(model.errorMessage == nil); #expect(model.result?.rows == [[value]])
        await run("SHOW standard_conforming_strings", on: model)
        #expect(model.result?.rows == [["off"]])
        await model.disconnectSQL()?.value
    }
    @Test func staleConfirmationPermissionsAndConstraintRejectionAreDefinite() async throws {
        try await reset(); let model = try model()
        await run("INSERT INTO records(id) VALUES(1)", on: model)
        model.sql = "INSERT INTO records(id) VALUES(2)"; await model.confirmSQL()?.value
        #expect(model.errorMessage == MobileSQLSessionError.staleConfirmation.localizedDescription)
        let reader = try self.model(reader: true)
        await run("INSERT INTO records(id) VALUES(3)", on: reader, confirm: true)
        #expect(reader.errorMessage != nil); #expect(!reader.writeOutcomeUncertain)
        await run("INSERT INTO records(id,amount) VALUES(4,-1)", on: model, confirm: true)
        #expect(model.errorMessage != nil); #expect(!model.writeOutcomeUncertain)
        #expect(try await query("SELECT count(*) FROM mobile_session.records").rows == [["0"]])
        await reader.disconnectSQL()?.value; await model.disconnectSQL()?.value
    }
    @Test func backgroundClosesTransactionAndReturningDoesNotReplay() async throws {
        try await reset(); let model = try model()
        await model.transaction(.begin)?.value
        await run("INSERT INTO records(id) VALUES(1)", on: model, confirm: true)
        #expect(model.transactionState == .inTransaction)
        model.setBackgrounded(true)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.transactionState == .disconnected); #expect(model.safetyLock.isEnabled)
        #expect(try await query("SELECT count(*) FROM mobile_session.records").rows == [["0"]])
        model.setBackgrounded(false); #expect(model.transactionState == .disconnected)
    }
    @Test func nativeStreamRejectsMultipleStatementsAndOversizedRowsWithoutReusingSocket() async throws {
        let client = LibPQClient(configuration: try config().postgreSQL)
        try await client.connect()
        await #expect(throws: PostgreSQLClientError.self) { try await client.queryStream("SELECT 1; SELECT 2", onBatch: { _ in }) }
        #expect(!(await client.isConnected()))
        try await client.connect()
        await #expect(throws: PostgreSQLQueryStreamError.rowTooLarge) { try await client.queryStream("SELECT repeat('x',1025)", maximumRowBytes: 1024, onBatch: { _ in }) }
        #expect(!(await client.isConnected()))
        await client.close()
    }
    @Test func lostCommitReplyBlocksModelUntilExplicitVerificationAndNeverReplays() async throws {
        try await reset()
        let session = MobileSQLSession(makeConnection: { LostPostgreSQLCommitReply(configuration: $0) })
        let model = try model(session: session)
        await model.transaction(.begin)?.value
        await run("INSERT INTO records(id) VALUES(77)", on: model, confirm: true)
        await model.transaction(.commit)?.value
        #expect(model.writeOutcomeUncertain); #expect(model.transactionState == .disconnected)
        #expect(model.safetyLock.isEnabled); #expect(model.execute() == nil); #expect(model.transaction(.commit) == nil)
        #expect(try await query("SELECT id FROM mobile_session.records").rows == [["77"]])
        model.acknowledgeUncertainOutcome()
        await run("SELECT id FROM records", on: model)
        #expect(model.errorMessage == nil); #expect(model.result?.rows == [["77"]])
        await model.disconnectSQL()?.value
    }
    @Test func cancelledReadRetainsEarlierResultAndNeverExecutesSuffix() async throws {
        let model = try model(), marker = "qc_session_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        model.sql = "SELECT 'retained'; SELECT pg_sleep(10) /* \(marker) */; SELECT 'never'"
        let task = try #require(model.executeAll())
        let deadline = ContinuousClock.now + .seconds(5)
        var running = false
        while ContinuousClock.now < deadline {
            let activity = try await query("SELECT count(*) FROM pg_stat_activity WHERE pid<>pg_backend_pid() AND state='active' AND query LIKE '%\(marker)%'")
            if activity.rows.first?.first == "1" { running = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        model.cancel(); await task.value
        #expect(running); #expect(!model.isLoading); #expect(model.transactionState == .disconnected)
        #expect(model.result?.rows == [["retained"]]); #expect(model.statementResults.map(\.phase) == [.completed, .stopped, .skipped])
        await model.disconnectSQL()?.value
    }
}

private struct LostPostgreSQLCommitReply: MobileSQLSessionConnection {
    let base: MobilePostgreSQLSessionConnection
    init(configuration: MobileSQLConfiguration) { base = .init(configuration: configuration) }
    func connect() async throws { try await base.connect() }
    func close() async { await base.close() }
    func query(_ sql: String) async throws { try await base.query(sql) }
    func isDefiniteRejection(_ error: any Error) -> Bool { base.isDefiniteRejection(error) }
    func queryStream(_ sql: String, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> MobileSQLStreamResult {
        let result = try await base.queryStream(sql, onBatch: onBatch)
        if sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("COMMIT") { throw URLError(.networkConnectionLost) }
        return result
    }
}
