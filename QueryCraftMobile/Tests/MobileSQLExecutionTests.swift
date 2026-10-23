import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileSQLExecutionTests {
    @Test func currentStatementUsesUTF16AndNeverExecutesNeighboursOrChangesDraft() async throws {
        let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        let text = "-- 雪 👋\nSELECT 'a;--b' AS first;\nSELECT 42 AS second;\nDELETE FROM t;"
        model.sql = text
        model.executionInput.selection = .init(location: (text as NSString).range(of: "42").location, length: 0)
        await model.execute()?.value
        #expect(await executor.statements == ["SELECT 42 AS second;"])
        #expect(model.lastExecutedSQL == "SELECT 42 AS second;"); #expect(model.sql == text)
        #expect(model.lastExecutedRange?.location == (text as NSString).range(of: "SELECT 42").location)
    }

    @Test func exactSelectionReadPrefixAndSetBranchUseDesktopPreflight() async throws {
        for (text, selected) in [
            ("SELECT 1;\n  SELECT 2;  \nSELECT 3;", "SELECT 2"),
            ("SELECT id,name FROM t WHERE id=1;", "SELECT id,name FROM t"),
            ("SELECT n FROM t WHERE n IS NOT NULL UNION ALL SELECT n FROM t WHERE n IS NULL;", "SELECT n FROM t WHERE n IS NOT NULL")
        ] {
            let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
            model.sql = text; model.executionInput.selection = (text as NSString).range(of: selected)
            await model.execute()?.value
            let actual = await executor.statements
            #expect(actual == [selected], "source=\(text), actual=\(actual), error=\(model.errorMessage ?? "none")"); #expect(model.sql == text)
        }
    }

    @Test func whitespaceAndSemicolonBoundaryMatchMacRatherThanSplitOnCharacters() async throws {
        let text = "SELECT ';' AS n;\n-- next\nSELECT 2;"
        let source = SQLSourceSnapshot(revision: .init(1), text: text)
        let snapshot = try await SQLStructuralParser().parse(source)
        for selection in [NSRange(location: (text as NSString).range(of: ";\n").location+1, length: 0),
                          NSRange(location: (text as NSString).range(of: "\nSELECT 2").location, length: 1)] {
            let expected = try SQLExecutionTargetResolver.resolve(.selectionOrCurrentStatement, source: source,
                selectedRange: selection, parseSnapshot: snapshot)
            let plan = try SQLExecutionBatchPreflight.makePlan(target: expected, parseSnapshot: snapshot)
            let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
            model.sql = text; model.executionInput.selection = selection; await model.execute()?.value
            #expect(await executor.statements == plan.statements.map(\.sql))
        }
    }

    @Test func unclassifiedPartialSubqueryUsesSameMacReadOnlyRejection() async throws {
        let text = "SELECT * FROM (SELECT 7 AS n) q;"
        let source = SQLSourceSnapshot(revision: .init(1), text: text), selection = (text as NSString).range(of: "SELECT 7 AS n")
        let plan = try await MobileSQLExecutionPlanner().plan(source: source, selection: selection)
        #expect(plan.containsUnclassifiedStatement); #expect(plan.requiresWriteAccess)
        let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        model.sql = text; model.executionInput.selection = selection
        await model.execute()?.value
        #expect(await executor.statements.isEmpty); #expect(model.errorMessage == MobileQueryError.readOnlySQLRequired.localizedDescription)
    }

    @Test func multiSelectionWritesTransactionsAndInvalidRangeNeverSendSQL() async throws {
        for (text, selection) in [
            ("UPDATE t SET name='x';SELECT 1;", NSRange(location: 0, length: 0)),
            ("BEGIN;SELECT 1;", NSRange(location: 0, length: 0)),
            ("SELECT 1;", NSRange(location: NSNotFound, length: 0)),
            ("SELECT 1;", NSRange(location: 100, length: 0))
        ] {
            let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
            model.sql = text; model.executionInput.selection = selection
            await model.execute()?.value
            #expect(await executor.statements.isEmpty); #expect(model.result == nil)
            #expect(model.errorMessage != nil); #expect(!model.isLoading)
        }
    }

    @Test func refreshRepeatsActualSQLAfterCaretAndDraftChangedAndWhenDraftEmpty() async throws {
        let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        model.sql = "SELECT 1;\nSELECT 2;"
        model.executionInput.selection = .init(location: 12, length: 0)
        await model.execute()?.value
        model.sql = "SELECT 99;"; model.executionInput.selection = .init(location: 0, length: 0)
        await model.refresh()?.value
        #expect(await executor.statements == ["SELECT 2;", "SELECT 2;"])
        #expect(model.sql == "SELECT 99;"); #expect(model.lastExecutedSQL == "SELECT 2;")
        model.sql = ""; await model.refresh()?.value
        #expect(await executor.statements.count == 3); #expect(model.sql == "")
    }

    @Test func failedReadRefreshRetriesCapturedSQLButNewEndpointClearsIt() async throws {
        let executor = TargetExecutor(failsFirst: true), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        model.sql = "SELECT 1;SELECT 2;"; model.executionInput.selection = .init(location: 12, length: 0)
        await model.execute()?.value
        #expect(model.errorMessage != nil)
        model.sql = "SELECT 3;"; model.executionInput.selection = .init(location: 0, length: 0)
        await model.refresh()?.value
        #expect(await executor.statements == ["SELECT 2;", "SELECT 2;"])
        model.host = "different.invalid"
        await model.refresh()?.value
        #expect(await executor.statements.last == "SELECT 3;")
    }

    @Test func sourceOrCaretChangesDuringPlanningRejectBeforeNetworkEvenIfTextReverted() async throws {
        for mode in 0..<3 {
            let executor = TargetExecutor(), planner = ExecutionPlanGate()
            let model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata(), executionPlanner: planner)
            model.sql = "SELECT 1;SELECT 2;"
            let operation = try #require(model.execute())
            #expect(await planner.waitForGate())
            if mode == 0 { model.executionInput.selection = .init(location: 12, length: 0) }
            else { let old = model.sql; model.sql = "SELECT 3;"; if mode == 2 { model.sql = old } }
            await planner.release(); await operation.value
            #expect(await executor.statements.isEmpty); #expect(model.errorMessage != nil)
        }
    }

    @Test func planningCancellationAndBackgroundCannotExecuteLatePlan() async throws {
        let executor = TargetExecutor(), planner = ExecutionPlanGate()
        let model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata(), executionPlanner: planner)
        model.sql = "SELECT 1;"
        let operation = try #require(model.execute()); #expect(await planner.waitForGate())
        model.setBackgrounded(true); await planner.release(); await operation.value
        #expect(await executor.statements.isEmpty); #expect(!model.isLoading)
        model.setBackgrounded(false); #expect(await executor.statements.isEmpty)
        await model.execute()?.value; #expect(await executor.statements == ["SELECT 1;"])
    }

    @Test func selectedSQLDrivesResultEditingAndPendingGuardsBothExecuteAndRefresh() async throws {
        let executor = TargetExecutor(), model = MobileQueryModel(executor: executor, metadataService: QueryEditingMetadata())
        model.database = "db"; model.sql = "SELECT 99;\nSELECT id,name FROM t;"
        model.executionInput.selection = (model.sql as NSString).range(of: "SELECT id,name FROM t;")
        await model.execute()?.value
        let editing = try #require(model.editing), page = try #require(model.editingPage)
        try editing.stage(editing.request(page: page, row: 0, column: 1), text: "pending", mode: .value)
        model.sql = "SELECT 123;"
        #expect(model.execute() == nil); #expect(model.refresh() == nil)
        #expect(await executor.statements == ["SELECT id,name FROM t;"])
        #expect(editing.hasChanges); #expect(model.lastExecutedSQL == "SELECT id,name FROM t;")
    }
}

private actor TargetExecutor: MobileQueryExecuting {
    private(set) var statements: [String] = []
    private let failsFirst: Bool
    init(failsFirst: Bool = false) { self.failsFirst = failsFirst }
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        statements.append(sql)
        if failsFirst, statements.count == 1 { throw CocoaError(.fileReadUnknown) }
        return try await QueryEditingExecutor().execute(configuration: configuration, sql: sql)
    }
}

private actor ExecutionPlanGate: MobileSQLExecutionPlanning {
    private var waiting = false, fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let planner = MobileSQLExecutionPlanner()
    func waitForGate() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !waiting, ContinuousClock.now < deadline { await Task.yield() }
        return waiting
    }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func plan(source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLExecutionBatchPlan {
        // Do not cooperate with cancellation until after the test releases us.
        if !fired { fired = true; waiting = true; await withCheckedContinuation { continuation = $0 } }
        return try await planner.plan(source: source, selection: selection)
    }
}
