import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileSQLSessionIntegrationTests {
    private func model(reader: Bool = false) throws -> MobileQueryModel {
        let config = try MobileSchemaIntegrationTests().config(reader: reader), model = MobileQueryModel()
        model.port = String(config.port); model.username = config.username; model.password = config.password ?? ""
        model.database = config.database ?? ""; model.tlsMode = .required
        return model
    }
    private func run(_ sql: String, on model: MobileQueryModel, confirm: Bool = false) async {
        model.sql = sql; model.executionInput.selection = .init(location: 0, length: 0)
        await model.executeAll()?.value
        if confirm { await model.confirmSQL()?.value }
    }

    @Test func diskCacheReadsBeyondPreviewAndPagesWithoutReexecutingSQL() async throws {
        let model = try model()
        let digits = "(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
        await run("SELECT a.n+10*b.n+100*c.n+1000*d.n+10000*e.n AS n, '雪' AS label, NULL AS absent FROM \(digits) a CROSS JOIN \(digits) b CROSS JOIN \(digits) c CROSS JOIN \(digits) d CROSS JOIN \(digits) e ORDER BY n", on: model)
        #expect(model.errorMessage == nil); #expect(model.cachedRowCount == 100_000)
        #expect(model.result?.rows.count == 500); #expect(model.preview?.isTruncated == false)
        let cache = try #require(model.statementResults.first?.cache)
        #expect(cache.store.isDiskBacked); #expect(cache.store.rowCount == 100_000)
        await model.pageCache(1)?.value
        #expect(model.cacheOffset == 500); #expect(model.result?.rows.first == ["500", "雪", nil])
        await model.pageCache(-1)?.value
        #expect(model.cacheOffset == 0); #expect(model.result?.rows.first == ["0", "雪", nil])
        let snapshot = try #require(model.queryExportSnapshot)
        var options = WorkspaceDataExportOptions(); options.scope = .allTableRows
        let request = try snapshot.request(options: options)
        var count = 0
        while let rows = try await request.source.nextBatch() { count += rows.count }
        await request.source.finish()
        #expect(count == 100_000)
        await model.disconnectSQL()?.value
    }

    @Test func writeConfirmationAffectedRowsDangerousReconfirmationAndRefreshNeverReplays() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_write (id INT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(80)) ENGINE=InnoDB")
        await run("INSERT INTO session_write(title) VALUES ('雪')", on: model)
        #expect(model.sqlConfirmation?.requiresUnlock == true)
        #expect(try await f.write("SELECT COUNT(*) FROM session_write").rows == [["0"]])
        await model.confirmSQL()?.value
        #expect(model.errorMessage == nil); #expect(model.result?.affectedRows == 1); #expect(model.result?.insertID == 1)
        await model.refresh()?.value
        #expect(model.errorMessage?.contains("不会重放") == true)
        #expect(try await f.write("SELECT COUNT(*) FROM session_write").rows == [["1"]])
        await run("UPDATE session_write SET title='changed' WHERE id=1", on: model)
        #expect(model.sqlConfirmation != nil); #expect(model.sqlConfirmation?.requiresUnlock == false)
        await model.confirmSQL()?.value
        #expect(model.errorMessage == nil); #expect(try await f.write("SELECT title FROM session_write").rows == [["changed"]])
        await model.disconnectSQL()?.value
    }

    @Test func immutableConfirmationRejectsChangedSQLAndServerPermissionsRemainEnforced() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_confirm (id INT PRIMARY KEY) ENGINE=InnoDB")
        await run("INSERT INTO session_confirm VALUES (1)", on: model)
        model.sql = "INSERT INTO session_confirm VALUES (2)"
        await model.confirmSQL()?.value
        #expect(model.errorMessage == MobileSQLSessionError.staleConfirmation.localizedDescription)
        #expect(model.safetyLock.isEnabled)
        #expect(try await f.write("SELECT COUNT(*) FROM session_confirm").rows == [["0"]])
        let reader = try self.model(reader: true)
        await run("INSERT INTO session_confirm VALUES (3)", on: reader, confirm: true)
        #expect(reader.errorMessage != nil); #expect(!reader.writeOutcomeUncertain)
        #expect(reader.transactionState == .disconnected)
        #expect(try await f.write("SELECT COUNT(*) FROM session_confirm").rows == [["0"]])
    }

    @Test func sameConnectionTransactionReadYourWritesSavepointRollbackAndCommit() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_transaction (id INT PRIMARY KEY) ENGINE=InnoDB")
        await model.transaction(.begin)?.value
        #expect(model.errorMessage == nil); #expect(model.transactionState == .inTransaction)
        await run("SELECT CONNECTION_ID()", on: model)
        let cid = model.result?.rows
        await run("INSERT INTO session_transaction VALUES (1)", on: model, confirm: true)
        #expect(model.transactionState == .inTransaction)
        #expect(try await f.write("SELECT COUNT(*) FROM session_transaction").rows == [["0"]])
        await run("SAVEPOINT qc; INSERT INTO session_transaction VALUES (2); ROLLBACK TO SAVEPOINT qc; SELECT id FROM session_transaction ORDER BY id; SELECT CONNECTION_ID();", on: model)
        #expect(model.errorMessage == nil); #expect(model.statementResults.count == 5)
        #expect(model.selectResult(model.statementResults[3].id)); #expect(model.result?.rows == [["1"]])
        #expect(model.selectResult(model.statementResults[4].id)); #expect(model.result?.rows == cid)
        model.safetyLock.enable()
        await model.transaction(.commit)?.value
        #expect(model.errorMessage == nil); #expect(model.transactionState == .autoCommit)
        #expect(try await f.write("SELECT id FROM session_transaction").rows == [["1"]])
        await model.transaction(.begin)?.value
        model.safetyLock.disable()
        await run("INSERT INTO session_transaction VALUES (3)", on: model)
        await model.transaction(.rollback)?.value
        #expect(model.errorMessage == nil); #expect(model.transactionState == .autoCommit)
        #expect(try await f.write("SELECT id FROM session_transaction").rows == [["1"]])
        await model.disconnectSQL()?.value
    }

    @Test func backgroundDisconnectRollsBackAndEndpointChangesAreBlockedDuringTransaction() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_background (id INT PRIMARY KEY) ENGINE=InnoDB")
        await model.transaction(.begin)?.value
        await run("INSERT INTO session_background VALUES (1)", on: model, confirm: true)
        let port = model.port; model.port = "1"
        #expect(model.port == port); #expect(model.hasPendingChanges)
        model.setBackgrounded(true)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.transactionState == .disconnected); #expect(model.safetyLock.isEnabled)
        #expect(try await f.write("SELECT COUNT(*) FROM session_background").rows == [["0"]])
        model.setBackgrounded(false)
        #expect(model.transactionState == .disconnected)
    }

    @Test func implicitDDLCommitUsesServerStateAndBatchFailureNeverExecutesSuffix() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_ddl_base (id INT PRIMARY KEY) ENGINE=InnoDB")
        await model.transaction(.begin)?.value
        await run("INSERT INTO session_ddl_base VALUES (1)", on: model, confirm: true)
        await run("CREATE TABLE session_ddl_new (id INT)", on: model)
        #expect(model.errorMessage == nil); #expect(model.transactionState == .autoCommit)
        #expect(try await f.write("SELECT id FROM session_ddl_base").rows == [["1"]])
        await run("SELECT 'retained'; SELECT * FROM missing_session_table; INSERT INTO session_ddl_base VALUES (2)", on: model)
        #expect(model.statementResults.map(\.phase) == [.completed, .failed, .skipped])
        #expect(try await f.write("SELECT id FROM session_ddl_base").rows == [["1"]])
    }

    @Test func cancellationKeepsExclusiveOwnershipAndCompletedDataUntilCleanup() async throws {
        let model = try model()
        model.sql = "SELECT 'completed'; SELECT SLEEP(10); SELECT 'never';"
        let task = try #require(model.executeAll())
        let deadline = ContinuousClock.now + .seconds(5)
        while model.statementResults.dropFirst().first?.phase != .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.cancel()
        #expect(model.isLoading); #expect(model.execute() == nil)
        await task.value
        #expect(!model.isLoading); #expect(model.transactionState == .disconnected)
        #expect(model.result?.rows == [["completed"]])
        #expect(model.statementResults.map(\.phase) == [.completed, .stopped, .skipped])
    }

    @Test func binaryNullAliasAndEmptyMetadataSurviveCacheAndServerFileWritesAreRejected() async throws {
        let model = try model()
        model.database = "querycraft_ios_proof"; model.username = "proof_reader"; model.password = "querycraft-proof-reader"
        await run("SELECT id AS alias_id,payload,NULL AS missing FROM sample ORDER BY id", on: model)
        #expect(model.preview?.cells.first?[1] == .binary(byteCount: 3, preview: [0,65,255]))
        #expect(model.preview?.cells.first?[2] == .null)
        #expect((model.result?.columnOrigins.first ?? nil)?.columnName == "id")
        await run("SELECT id AS alias_id,payload FROM sample WHERE id<0", on: model)
        #expect(model.errorMessage == nil); #expect(model.result?.columns == ["alias_id","payload"]); #expect(model.result?.rows.isEmpty == true)
        model.safetyLock.disable()
        await run("SELECT id INTO OUTFILE '/tmp/querycraft-no-file' FROM sample", on: model)
        #expect(model.errorMessage != nil)
        await model.disconnectSQL()?.value
    }

    @Test func interruptedWriteRequiresVerificationAndIsNeverReplayed() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_cancel_write (id INT PRIMARY KEY, n INT) ENGINE=InnoDB")
        _ = try await f.write("INSERT INTO session_cancel_write VALUES (1,0)")
        await run("UPDATE session_cancel_write SET n=n+SLEEP(10)+1 WHERE id=1", on: model)
        let task = try #require(model.confirmSQL())
        let deadline = ContinuousClock.now + .seconds(5)
        while model.statementResults.first?.phase != .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(150))
        model.cancel(); #expect(model.execute() == nil)
        await task.value
        #expect(model.writeOutcomeUncertain); #expect(model.transactionState == .disconnected)
        #expect(model.safetyLock.isEnabled); #expect(model.hasPendingChanges)
        #expect(model.execute() == nil)
        #expect(try await f.write("SELECT n FROM session_cancel_write").rows == [["0"]])
        model.acknowledgeUncertainOutcome()
        await run("SELECT n FROM session_cancel_write", on: model)
        #expect(model.errorMessage == nil); #expect(model.result?.rows == [["0"]])
        await model.disconnectSQL()?.value
    }

    @Test func refreshBeforeAnyResultOrAfterFailedWriteCannotFallBackToEditorExecution() async throws {
        let f = MobileSchemaIntegrationTests(), model = try model()
        _ = try await f.write("CREATE TABLE session_refresh_guard (id INT PRIMARY KEY) ENGINE=InnoDB")
        model.safetyLock.disable()
        model.sql = "INSERT INTO session_refresh_guard VALUES (1)"
        await model.refresh()?.value
        #expect(model.errorMessage != nil)
        #expect(try await f.write("SELECT COUNT(*) FROM session_refresh_guard").rows == [["0"]])
        await run("SELECT 'retained'", on: model)
        await run("INSERT INTO session_refresh_missing VALUES (1)", on: model)
        #expect(model.errorMessage != nil); #expect(model.result?.rows == [["retained"]])
        _ = try await f.write("CREATE TABLE session_refresh_missing (id INT PRIMARY KEY) ENGINE=InnoDB")
        await model.refresh()?.value
        #expect(model.errorMessage?.contains("不会重放") == true)
        #expect(try await f.write("SELECT COUNT(*) FROM session_refresh_missing").rows == [["0"]])
        await model.disconnectSQL()?.value
    }
}
