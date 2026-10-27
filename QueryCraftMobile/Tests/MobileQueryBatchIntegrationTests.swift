import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileQueryBatchIntegrationTests {
    private func model() throws -> MobileQueryModel {
        let port = try #require(ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"].flatMap(Int.init))
        let model = MobileQueryModel()
        model.host = MobileFixtureEndpoint.host; model.port = String(port); model.username = "proof_reader"; model.password = "querycraft-proof-reader"
        model.database = "querycraft_ios_proof"; model.tlsMode = .required
        return model
    }

    @Test func oneServerSessionProducesDistinctResultsAndRealEmptyMetadata() async throws {
        let model = try model()
        model.sql = "SELECT CONNECTION_ID() AS cid; SELECT CONNECTION_ID() AS cid, '雪;👋' AS label; SELECT id,name FROM sample WHERE id<0;"
        await model.executeAll()?.value
        #expect(model.errorMessage == nil)
        #expect(model.statementResults.count == 3)
        let first = try #require(model.result?.rows.first?.first ?? nil)
        #expect(model.selectResult(model.statementResults[1].id))
        #expect(model.result?.rows == [[first, "雪;👋"]])
        #expect(model.selectResult(model.statementResults[2].id))
        #expect(model.result?.rows.isEmpty == true); #expect(model.result?.columns == ["id", "name"])
        #expect((model.result?.columnOrigins.first ?? nil)?.columnName == "id")
        #expect(model.editingPage?.columns.first?.comment == "primary identifier")
        model.sql = "SELECT 999;"
        await model.refresh()?.value
        #expect(model.result?.rows.isEmpty == true); #expect(model.sql == "SELECT 999;")
        #expect(model.statementResults[0].result?.rows == [[first]])
    }

    @Test func serverFailureStopsSuffixAndLargeResultsKeepFollowingStatements() async throws {
        let model = try model()
        model.sql = "SELECT 'first' AS n; SELECT * FROM querycraft_ios_proof.missing_batch_table; SELECT 'never' AS n;"
        await model.executeAll()?.value
        #expect(model.errorMessage != nil)
        #expect(model.statementResults.map(\.phase) == [.completed, .failed, .skipped])
        #expect(model.result?.rows == [["first"]])
        model.sql = "WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<501) SELECT n FROM s; SELECT 'never' AS n;"
        await model.executeAll()?.value
        #expect(model.statementResults.map(\.phase) == [.completed, .completed])
        #expect(model.preview?.isTruncated == false); #expect(model.result?.rows.count == 500)
        #expect(model.cachedRowCount == 501); #expect(model.errorMessage == nil)
    }

    @Test func readOnlyPreflightRejectsEntireBatchAndCancellationStopsRunningServerRead() async throws {
        let model = try model()
        model.sql = "SELECT 1; DELETE FROM sample;"
        await model.executeAll()?.value
        #expect(model.sqlConfirmation != nil); #expect(model.result == nil)
        model.sqlConfirmation = nil
        model.sql = "SELECT 'retained' AS n; SELECT SLEEP(10); SELECT 'never' AS n;"
        let task = try #require(model.executeAll())
        let deadline = ContinuousClock.now + .seconds(5)
        while model.statementResults.dropFirst().first?.phase != .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.statementResults.first?.phase == .completed)
        model.cancel(); await task.value
        #expect(model.result?.rows == [["retained"]])
        #expect(model.statementResults.map(\.phase) == [.completed, .stopped, .skipped])
    }
}
