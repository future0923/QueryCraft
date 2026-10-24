import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileQueryBatchTests {
    @Test func selectionRunsOnlyCompleteSelectedStatementsAndPreservesIndependentResults() async throws {
        let executor = BatchTestExecutor(), model = MobileQueryModel(executor: executor)
        let text = "SELECT 99;\nSELECT '雪;👋' AS n; SELECT 2;\nSELECT 100;"
        let selected = "SELECT '雪;👋' AS n; SELECT 2;"
        model.sql = text; model.executionInput.selection = (text as NSString).range(of: selected)
        await model.execute()?.value
        #expect(model.errorMessage == nil)
        #expect(await executor.statements == ["SELECT '雪;👋' AS n;", "SELECT 2;"])
        #expect(model.statementResults.count == 2)
        let first = model.statementResults[0], second = model.statementResults[1]
        #expect(model.result?.rows == [["1"]]); #expect(model.sql == text)
        first.viewport.offset = .init(x: 40, y: 80)
        #expect(model.selectResult(second.id)); #expect(model.result?.rows == [["2"]])
        #expect(model.lastExecutedSQL == "SELECT 2;")
        #expect(model.selectResult(first.id)); #expect(model.result?.rows == [["1"]])
        #expect(model.resultViewport === first.viewport); #expect(model.resultViewport.offset.y == 80)
        #expect(first.resultID != second.resultID)
    }

    @Test func wholeDocumentPreflightsAllStatementsBeforeAnyNetworkAndBoundsCount() async throws {
        for text in ["SELECT 1; DELETE FROM t;", "SELECT 1; BEGIN; SELECT 2;",
                     (1...21).map { "SELECT \($0);" }.joined()] {
            let executor = BatchTestExecutor(), model = MobileQueryModel(executor: executor)
            model.sql = text
            await model.executeAll()?.value
            #expect(await executor.statements.isEmpty)
            #expect(model.errorMessage != nil); #expect(model.result == nil)
        }
    }

    @Test func defaultExecutorValidatesEveryReadBeforeSendingTheFirst() async throws {
        let executor = BatchTestExecutor(), model = MobileQueryModel(executor: executor)
        model.sql = "SELECT 1; EXPLAIN DELETE FROM t;"
        await model.executeAll()?.value
        #expect(await executor.statements.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func failureStopsTheSuffixAndRefreshRetriesOnlyTheChosenStatement() async throws {
        let executor = BatchTestExecutor(failsOnce: "SELECT 2;"), model = MobileQueryModel(executor: executor)
        model.sql = "SELECT 1;SELECT 2;SELECT 3;"
        await model.executeAll()?.value
        #expect(await executor.statements == ["SELECT 1;", "SELECT 2;"])
        let results = model.statementResults
        #expect(results.map(\.phase) == [.completed, .failed, .skipped])
        #expect(model.result?.rows == [["1"]]); #expect(model.errorMessage != nil)
        #expect(model.selectResult(results[1].id))
        model.sql = "SELECT 999;"
        await model.refresh()?.value
        #expect(await executor.statements == ["SELECT 1;", "SELECT 2;", "SELECT 2;"])
        #expect(model.lastExecutedSQL == "SELECT 2;"); #expect(model.sql == "SELECT 999;")
        #expect(results[1].phase == .completed); #expect(results[2].phase == .skipped)
        #expect(model.selectResult(results[0].id)); #expect(model.result?.rows == [["1"]])
    }

    @Test func firstFailureKeepsPreviousDataLabelledAndRetryUsesTheFailedSQL() async throws {
        let executor = BatchTestExecutor(failsOnce: "SELECT 2;"), model = MobileQueryModel(executor: executor)
        model.sql = "SELECT 1;"; await model.execute()?.value
        let old = model.result, identity = model.resultID
        model.sql = "SELECT 2;SELECT 3;"; await model.executeAll()?.value
        #expect(model.result == old); #expect(model.resultID == identity)
        #expect(model.statementResults.last?.isPreviousBatch == true)
        await model.refresh()?.value
        #expect(await executor.statements == ["SELECT 1;", "SELECT 2;", "SELECT 2;"])
        #expect(model.lastExecutedSQL == "SELECT 2;")
        #expect(model.statementResults.count == 1)
    }

    @Test func truncationAndAggregateBudgetPreserveFinishedResultsAndDoNotReconnect() async throws {
        for truncated in [true, false] {
            let executor = BatchTestExecutor(truncated: truncated, large: !truncated), model = MobileQueryModel(executor: executor)
            model.sql = "SELECT 1;SELECT 2;SELECT 3;"
            await model.executeAll()?.value
            #expect(await executor.statements.count == (truncated ? 1 : 2))
            #expect(model.statementResults.last?.phase == .skipped)
            #expect(model.statementResults.first?.phase == .completed)
            #expect(model.errorMessage != nil); #expect(model.result != nil)
        }
    }

    @Test func cancellationAndEndpointSwitchRejectLateResultAndNeverExecuteSuffix() async throws {
        for changeEndpoint in [false, true] {
            let executor = BatchTestExecutor(gatesSecond: true), model = MobileQueryModel(executor: executor)
            model.sql = "SELECT 1;SELECT 2;SELECT 3;"
            let task = try #require(model.executeAll())
            await executor.waitForGate()
            #expect(model.result?.rows == [["1"]])
            let records = model.statementResults
            if changeEndpoint { model.host = "different.invalid" } else { model.setBackgrounded(true) }
            await executor.release(); await task.value
            #expect(await executor.statements.count == 2)
            #expect(records[1].phase == .stopped); #expect(records[2].phase == .skipped)
            if changeEndpoint { #expect(model.statementResults.isEmpty); #expect(model.result == nil) }
            else { #expect(model.result?.rows == [["1"]]); model.setBackgrounded(false); #expect(model.isLoading == false) }
        }
    }

    @Test func hiddenDraftsBlockNewExecutionEndpointChangesAndTableActionsWithoutBeingLost() async throws {
        let model = MobileQueryModel(executor: QueryEditingExecutor(), metadataService: QueryEditingMetadata())
        model.database = "db"; model.sql = "SELECT id,name FROM t;SELECT id,name FROM t;"
        await model.executeAll()?.value
        #expect(model.errorMessage == nil)
        let first = try #require(model.statementResults.first)
        let edits = try #require(model.editing), page = try #require(model.editingPage)
        try edits.stage(edits.request(page: page, row: 0, column: 1), text: "draft", mode: .value)
        #expect(model.selectResult(model.statementResults[1].id))
        #expect(model.hasPendingChanges); #expect(model.hasPendingChanges(for: edits.object))
        #expect(model.executeAll() == nil); #expect(model.refresh() == nil)
        model.host = "different.invalid"; #expect(model.host == "127.0.0.1")
        #expect(model.selectResult(first.id)); #expect(model.editing === edits); #expect(edits.hasChanges)
    }

    @Test func historyReceivesEachSuccessfulStatementExactlyAtCompletionNotOnSelection() async throws {
        let model = MobileQueryModel(executor: BatchTestExecutor())
        var recorded: [String] = []
        model.didExecute = { sql, _, _ in recorded.append(sql) }
        model.sql = "SELECT 1;SELECT 2;"; await model.executeAll()?.value
        #expect(recorded == ["SELECT 1;", "SELECT 2;"])
        #expect(model.selectResult(model.statementResults[1].id))
        #expect(model.selectResult(model.statementResults[0].id))
        #expect(recorded.count == 2)
    }
}

private actor BatchTestExecutor: MobileQueryExecuting {
    private(set) var statements: [String] = []
    private var failsOnce: String?
    private let truncated: Bool, large: Bool, gatesSecond: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var gated = false
    init(failsOnce: String? = nil, truncated: Bool = false, large: Bool = false, gatesSecond: Bool = false) {
        self.failsOnce = failsOnce; self.truncated = truncated; self.large = large; self.gatesSecond = gatesSecond
    }
    func waitForGate() async { if !gated { await withCheckedContinuation { waiting = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        try await preview(configuration: configuration, sql: sql, maximumRows: 500, maximumBytes: 4_194_304).result
    }
    func preview(configuration: MobileSQLConfiguration, sql: String, maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview {
        statements.append(sql)
        if gatesSecond, statements.count == 2 {
            await withCheckedContinuation { continuation = $0; gated = true; waiting?.resume(); waiting = nil }
        }
        if failsOnce == sql { failsOnce = nil; throw CocoaError(.fileReadUnknown) }
        let value = large ? String(repeating: "a", count: 4_194_304) : String(statements.count)
        return .init(result: .init(columns: ["n"], rows: [[value]]), isTruncated: truncated)
    }
}
