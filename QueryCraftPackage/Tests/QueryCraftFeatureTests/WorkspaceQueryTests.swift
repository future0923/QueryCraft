import CodeEditLanguages
import CodeEditTextView
import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceQueryResultStoreTests {
    @Test
    func appendsBatchesAndReadsAcrossCachePages() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let rows = (0..<600).map { index in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [.text("row-\(index)"), .null]
            )
        }

        try await store.append(Array(rows[..<173]))
        try await store.append(Array(rows[173..<419]))
        try await store.append(Array(rows[419...]))

        #expect(store.rowCount == 600)
        for index in [0, 172, 255, 256, 418, 511, 599] {
            #expect(store.row(at: index) == rows[index])
        }
        #expect(store.row(at: -1) == nil)
        #expect(store.row(at: 600) == nil)
    }

    @Test
    func diskBackedRowsEvictAndReloadCachePagesAsynchronously() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let pageSize = 256
        let pageCount = 197

        for pageIndex in 0..<pageCount {
            let rows = (0..<pageSize).map { offset in
                let index = pageIndex * pageSize + offset
                return WorkspaceDatabaseDataRow(
                    id: index,
                    values: [.text("row-\(index)")]
                )
            }
            try await store.append(rows)
        }

        let lastIndex = pageCount * pageSize - 1
        #expect(store.isDiskBacked)
        #expect(store.cachedRow(at: lastIndex)?.id == lastIndex)
        #expect(store.cachedRow(at: 0) == nil)

        let loadedRange = try await store.loadPage(containing: 0)

        #expect(loadedRange == 0..<pageSize)
        #expect(store.cachedRow(at: 0)?.values == [.text("row-0")])
    }

    @Test
    func representativeQueryResultsRemainDirectlyAvailableInMemory() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let rows = (0..<30_000).map { index in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [.text("row-\(index)"), .null]
            )
        }

        try await store.append(rows)

        #expect(store.rowCount == rows.count)
        #expect(!store.isDiskBacked)
        #expect(store.cachedRow(at: 0) == rows[0])
        #expect(store.cachedRow(at: 14_999) == rows[14_999])
        #expect(store.cachedRow(at: 29_999) == rows[29_999])
    }

    @Test
    func exportSourceStreamsTemporaryResultsInLargeBatches() async throws {
        let store = try WorkspaceQueryResultStore()
        let rows = (0..<12_050).map { index in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [.text("row-\(index)")]
            )
        }
        try await store.append(rows)
        let source = store.makeDataExportRowSource(
            rows: .range(0...12_049)
        )

        var batchSizes: [Int] = []
        var exportedIDs: [Int] = []
        while let batch = try await source.nextBatch() {
            batchSizes.append(batch.count)
            exportedIDs.append(contentsOf: batch.map(\.id))
        }
        await source.finish()

        #expect(batchSizes == [5_000, 5_000, 2_050])
        #expect(exportedIDs == Array(0..<12_050))
    }

    @Test
    func exportSourcePreservesSparseResultSelection() async throws {
        let store = try WorkspaceQueryResultStore()
        let rows = (0..<2_000).map { index in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [.text("row-\(index)")]
            )
        }
        try await store.append(rows)
        let selectedIndexes = IndexSet([2, 17, 900, 1_024, 1_999])
        let source = store.makeDataExportRowSource(
            rows: .indexes(selectedIndexes)
        )

        let batch = try #require(try await source.nextBatch())
        await source.finish()

        #expect(batch.map(\.id) == Array(selectedIndexes))
    }
}

@MainActor
struct WorkspaceQueryDocumentTests {
    @Test
    func structuralTransactionFallbackTracksOnlyCertainState() throws {
        #expect(
            try WorkspaceQueryTransactionState.autoCommit
                .afterSuccessfulStatement(.transaction(.begin))
                == .inTransaction
        )
        #expect(
            try WorkspaceQueryTransactionState.inTransaction
                .afterSuccessfulStatement(.read)
                == .inTransaction
        )
        #expect(
            try WorkspaceQueryTransactionState.inTransaction
                .afterSuccessfulStatement(.transaction(.rollback))
                == .autoCommit
        )
        #expect(
            try WorkspaceQueryTransactionState.inTransaction
                .afterSuccessfulStatement(.transaction(.savepoint))
                == .inTransaction
        )
        #expect(
            try WorkspaceQueryTransactionState.autoCommit
                .afterSuccessfulStatement(.ddl(.create))
                == .autoCommit
        )
        #expect(throws: WorkspaceSessionError.self) {
            try WorkspaceQueryTransactionState.inTransaction
                .afterSuccessfulStatement(.ddl(.alter))
        }
        #expect(throws: WorkspaceSessionError.self) {
            try WorkspaceQueryTransactionState.autoCommit
                .afterSuccessfulStatement(.control)
        }
    }

    @Test
    func executesAReadOnlyQueryAndStoresItsResult() async throws {
        let configuration = makeConfiguration(database: "app_database")
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: configuration,
            sessionFactory: InMemoryWorkspaceSessionFactory(
                databases: ["app_database"]
            )
        )
        document.sql = "SELECT 1"

        await document.execute(try executionTarget(for: document.sql))

        guard case let .completed(page) = document.executionState else {
            Issue.record("Expected a completed query result.")
            return
        }
        #expect(page.rowCount == 1)
        #expect(page.row(at: 0)?.values == [.text("1")])
        await document.close()
    }

    @Test
    func dismissingACompletedResultReturnsTheDocumentToIdle() async throws {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )

        await document.execute(try executionTarget(for: "SELECT 1"))
        guard case .completed = document.executionState else {
            Issue.record("Expected a completed query result.")
            return
        }

        document.dismissResults()

        #expect(document.executionState == .idle)
        #expect(document.executionState.page == nil)
        #expect(document.elapsedSeconds == 0)
        await document.close()
    }

    @Test
    func commandShiftReturnRunsEachReliableReadOnlyStatement() async {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        document.sql = "SELECT 1;\nSELECT 2;"
        let textView = TextView(string: document.sql)
        let languageService = WorkspaceSQLLanguageService()
        languageService.setUp(textView: textView, codeLanguage: .sql)
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService
        )

        #expect(
            coordinator.handleTextViewKeyCommand(
                .commandShiftReturn,
                textView: textView
            )
        )
        for _ in 0..<1_000 where document.statementResults.count != 2
            || document.executionState.isRunning
        {
            await Task.yield()
        }

        #expect(document.statementResults.count == 2)
        #expect(
            document.statementResults.allSatisfy {
                if case .completed = $0.state { true } else { false }
            }
        )
        #expect(!document.executionState.isRunning)
        await document.close()
    }

    @Test
    func aWriteInTheBatchIsRejectedBeforeOpeningAQuerySession() async throws {
        let factory = RecordingQuerySessionFactory()
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: factory
        )
        let sql = "SELECT 1;\nUPDATE users SET active = 0;"

        await document.execute(try await executionPlan(for: sql))

        guard case let .failed(message, _) = document.executionState else {
            Issue.record("Expected the write batch to fail closed.")
            return
        }
        #expect(
            message
                == SQLExecutionPolicyError.safetyLockEnabled
                    .localizedDescription
        )
        #expect(document.statementResults.isEmpty)
        #expect(await factory.configurations.isEmpty)
        await document.close()
    }

    @Test
    func aBatchStopsAtTheFirstFailureAndMarksLaterStatementsSkipped() async throws {
        let session = FailingBatchQuerySession(failingStatementIndex: 1)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )

        await document.execute(
            try await executionPlan(
                for: "SELECT 1;\nSELECT 2;\nSELECT 3;"
            )
        )

        #expect(document.statementResults.count == 3)
        if case .completed = document.statementResults[0].state {
            // Expected.
        } else {
            Issue.record("Expected the first statement to remain completed.")
        }
        if case .failed = document.statementResults[1].state {
            // Expected.
        } else {
            Issue.record("Expected the second statement to fail.")
        }
        #expect(
            document.statementResults[2].state
                == .skipped(
                    reason: AppCopy.current.text(
                        "由于语句 2 失败，已跳过：\(WorkspaceSessionError.queryUnavailable.localizedDescription)",
                        "Skipped because Statement 2 failed: \(WorkspaceSessionError.queryUnavailable.localizedDescription)"
                    )
                )
        )
        #expect(await session.executedStatements() == ["SELECT 1;", "SELECT 2;"])
        await document.close()
    }

    @Test
    func writeAccessPolicyExecutesAWriteStatementExactlyOnce() async throws {
        let session = FailingBatchQuerySession(failingStatementIndex: .max)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )
        let plan = try await executionPlan(
            for: "UPDATE users SET active = 0;"
        )
        #expect(plan.requiresWriteAccess)

        await document.execute(plan, policy: .writesAllowed)

        #expect(document.statementResults.count == 1)
        guard case .completed = document.statementResults[0].state else {
            Issue.record("Expected the authorized write to complete.")
            return
        }
        #expect(await session.executedStatements() == ["UPDATE users SET active = 0;"])
        #expect(await session.readOnlyStatements().isEmpty)
        #expect(await session.writableStatements() == ["UPDATE users SET active = 0;"])
        await document.close()
    }

    @Test
    func safetyLockDefaultsOnAndResetsWithANewWorkspaceLifetime() {
        let safetyLock = WorkspaceSafetyLock()

        #expect(safetyLock.isEnabled)
        safetyLock.disable()
        #expect(!safetyLock.isEnabled)
        safetyLock.enable()
        #expect(safetyLock.isEnabled)

        safetyLock.disable()
        #expect(WorkspaceSafetyLock().isEnabled)
    }

    @Test
    func safetyLockBlocksWritesButNeverReadOnlyQueries() async throws {
        let safetyLock = WorkspaceSafetyLock()
        let readPlan = try await executionPlan(for: "SELECT 1;")
        let writePlan = try await executionPlan(
            for: "UPDATE users SET active = 0 WHERE id = 1;"
        )

        #expect(
            try safetyLock.executionPolicy(for: readPlan) == .readOnly
        )
        #expect(throws: SQLExecutionPolicyError.safetyLockEnabled) {
            try safetyLock.executionPolicy(for: writePlan)
        }

        safetyLock.disable()
        #expect(
            try safetyLock.executionPolicy(for: readPlan) == .readOnly
        )
        #expect(
            try safetyLock.executionPolicy(for: writePlan) == .writesAllowed
        )
    }

    @Test
    func safetyLockNamesUnclassifiedSQLWithoutCallingItASyntaxError() async throws {
        let text = "SELECT 1;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: text
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: (text as NSString).range(of: "LECT 1"),
            parseSnapshot: snapshot
        )
        let plan = try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )
        let safetyLock = WorkspaceSafetyLock()

        #expect(throws: SQLExecutionPolicyError.unclassifiedStatement) {
            try safetyLock.executionPolicy(for: plan)
        }
        safetyLock.disable()
        #expect(try safetyLock.executionPolicy(for: plan) == .writesAllowed)
    }

    @Test
    func executableCommentsRequireUnlockAndExecuteUnchanged() async throws {
        let sql = "SELECT 1 /*!80000 SQL_NO_CACHE */;"
        let plan = try await executionPlan(for: sql)
        let safetyLock = WorkspaceSafetyLock()

        #expect(plan.statements.map(\.kind) == [.unknown])
        #expect(throws: SQLExecutionPolicyError.unclassifiedStatement) {
            try safetyLock.executionPolicy(for: plan)
        }

        safetyLock.disable()
        let policy = try safetyLock.executionPolicy(for: plan)
        let session = FailingBatchQuerySession(failingStatementIndex: .max)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )
        await document.execute(plan, policy: policy)

        #expect(await session.executedStatements() == [sql])
        await document.close()
    }

    @Test
    func transactionCommandsDoNotRequireDisablingSafetyLock() async throws {
        let safetyLock = WorkspaceSafetyLock()
        let plan = try await executionPlan(
            for: "START TRANSACTION;\nCOMMIT;\nROLLBACK;"
        )

        #expect(!plan.requiresWriteAccess)
        #expect(try safetyLock.executionPolicy(for: plan) == .readOnly)
    }

    @Test
    func transactionStatePersistsAndReadsUseTheDocumentSession() async throws {
        let session = FailingBatchQuerySession(failingStatementIndex: .max)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )

        await document.execute(try await executionPlan(for: "START TRANSACTION;"))
        #expect(document.transactionState == .inTransaction)

        await document.execute(try await executionPlan(for: "SELECT 1;"))
        #expect(document.transactionState == .inTransaction)
        #expect(await session.readOnlyStatements().isEmpty)
        #expect(
            await session.writableStatements()
                == ["START TRANSACTION;", "SELECT 1;"]
        )

        await document.execute(try await executionPlan(for: "COMMIT;"))
        #expect(document.transactionState == .autoCommit)

        await document.execute(try await executionPlan(for: "SELECT 2;"))
        #expect(await session.readOnlyStatements() == ["SELECT 2;"])
        await document.close()
    }

    @Test
    func transactionShortcutsTakePriorityWhileTheEditorHasAnActiveTransaction() async throws {
        let session = FailingBatchQuerySession(failingStatementIndex: .max)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: WorkspaceSQLLanguageService()
        )
        let textView = TextView(string: "SELECT 1;")

        #expect(
            !coordinator.handleTextViewKeyCommand(
                .commitTransaction,
                textView: textView
            )
        )

        await document.execute(try await executionPlan(for: "BEGIN;"))
        #expect(document.transactionState == .inTransaction)
        #expect(
            coordinator.handleTextViewKeyCommand(
                .commitTransaction,
                textView: textView
            )
        )
        for _ in 0..<1_000 where document.transactionState == .inTransaction {
            await Task.yield()
        }
        #expect(document.transactionState == .autoCommit)

        await document.execute(try await executionPlan(for: "BEGIN;"))
        #expect(document.transactionState == .inTransaction)
        #expect(
            coordinator.handleTextViewKeyCommand(
                .rollbackTransaction,
                textView: textView
            )
        )
        for _ in 0..<1_000 where document.transactionState == .inTransaction {
            await Task.yield()
        }
        #expect(document.transactionState == .autoCommit)
        #expect(
            await session.writableStatements()
                == ["BEGIN;", "COMMIT;", "BEGIN;", "ROLLBACK;"]
        )
        await document.close()
    }

    @Test
    func beginThenExactRollbackSelectionCompletesTheTransactionFlow() async throws {
        let sql = "BEGIN;\n\nROLLBACK;"
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let session = FailingBatchQuerySession(failingStatementIndex: .max)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )
        let beginTarget = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: NSRange(location: 1, length: 0),
            parseSnapshot: snapshot
        )
        let beginPlan = try SQLExecutionBatchPreflight.makePlan(
            target: beginTarget,
            parseSnapshot: snapshot
        )
        let rollbackTarget = try SQLExecutionTargetResolver.resolve(
            .selectionOrCurrentStatement,
            source: source,
            selectedRange: (sql as NSString).range(of: "ROLLBACK"),
            parseSnapshot: snapshot
        )
        let rollbackPlan = try SQLExecutionBatchPreflight.makePlan(
            target: rollbackTarget,
            parseSnapshot: snapshot
        )

        #expect(beginPlan.statements.map(\.sql) == ["BEGIN;"])
        #expect(rollbackPlan.statements.map(\.sql) == ["ROLLBACK"])
        await document.execute(beginPlan)
        #expect(document.transactionState == .inTransaction)
        await document.execute(rollbackPlan)
        #expect(document.transactionState == .autoCommit)
        #expect(await session.writableStatements() == ["BEGIN;", "ROLLBACK"])
        await document.close()
    }

    @Test
    func closeRollsBackAnActiveTransactionBeforeClosingTheSession() async throws {
        let session = FailingBatchQuerySession(failingStatementIndex: .max)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )

        await document.execute(try await executionPlan(for: "BEGIN;"))
        let result = await document.close()

        #expect(result == .closed)
        #expect(
            await session.writableStatements() == ["BEGIN;", "ROLLBACK;"]
        )
        #expect(await session.wasClosed())
        #expect(document.transactionState == .disconnected)
    }

    @Test
    func rollbackFailureKeepsTheDocumentOpenForRetry() async throws {
        let session = FailingBatchQuerySession(failingStatementIndex: 1)
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )

        await document.execute(try await executionPlan(for: "BEGIN;"))
        let firstClose = await document.close()

        guard case .failed = firstClose else {
            Issue.record("Expected close to preserve a document after rollback failed.")
            return
        }
        #expect(document.transactionState == .inTransaction)
        #expect(!(await session.wasClosed()))

        #expect(await document.close() == .closed)
        #expect(await session.wasClosed())
    }

    @Test
    func explicitTargetDoesNotPerformLocalSyntaxValidation() async throws {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )

        await document.execute(try executionTarget(for: "SELECT 1"))
        guard case .completed = document.executionState else {
            Issue.record("Expected the first query to complete.")
            return
        }

        await document.execute(
            try executionTarget(for: "SELECT 1;\nSELECT 2;")
        )

        guard case .completed = document.executionState else {
            Issue.record("Expected the database session to own SQL validation.")
            return
        }
        await document.close()
    }

    @Test
    func targetFailureAfterSuccessReplacesThePreviousResult() async throws {
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )

        await document.execute(try executionTarget(for: "SELECT 1"))
        guard case .completed = document.executionState else {
            Issue.record("Expected the first query to complete.")
            return
        }

        document.reportExecutionTargetFailure(
            SQLExecutionTargetError.unreliableCurrentStatement
        )

        guard case let .failed(message, page) = document.executionState else {
            Issue.record("Expected target resolution to fail.")
            return
        }
        #expect(
            message == SQLExecutionTargetError.unreliableCurrentStatement
                .localizedDescription
        )
        #expect(page == nil)
        await document.close()
    }

    @Test
    func escapeKeepsRowsAndKillsTheServerQueryWhileRunning() async throws {
        let release = QueryTestSignal()
        let firstBatch = QueryTestSignal()
        let querySession = ControlledQuerySession(
            role: .query,
            release: release,
            firstBatch: firstBatch
        )
        let controlSession = ControlledQuerySession(
            role: .control,
            release: release,
            firstBatch: firstBatch
        )
        let factory = QuerySessionSequenceFactory(
            sessions: [querySession, controlSession]
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: factory
        )
        document.sql = "SELECT 1"

        let target = try executionTarget(for: document.sql)
        let execution = Task { await document.execute(target) }
        await firstBatch.wait()
        let languageService = WorkspaceSQLLanguageService()
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService
        )
        let textView = TextView(string: document.sql)
        #expect(
            coordinator.handleTextViewKeyCommand(
                .escape,
                textView: textView
            )
        )
        await execution.value

        guard case let .stopped(page?) = document.executionState else {
            Issue.record("Expected a stopped query with its partial result.")
            return
        }
        #expect(page.rowCount == 1)
        #expect(page.row(at: 0)?.values == [.text("first")])
        #expect(await controlSession.cancelledConnectionID() == 41)
        #expect(await controlSession.wasClosed())
        #expect(
            !coordinator.handleTextViewKeyCommand(
                .escape,
                textView: textView
            )
        )
        await document.close()
    }

    @Test
    func stoppingABatchKeepsPartialRowsAndSkipsLaterStatements() async throws {
        let release = QueryTestSignal()
        let firstBatch = QueryTestSignal()
        let querySession = ControlledQuerySession(
            role: .query,
            release: release,
            firstBatch: firstBatch
        )
        let controlSession = ControlledQuerySession(
            role: .control,
            release: release,
            firstBatch: firstBatch
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: QuerySessionSequenceFactory(
                sessions: [querySession, controlSession]
            )
        )
        let plan = try await executionPlan(for: "SELECT 1;\nSELECT 2;")

        let execution = Task { await document.execute(plan) }
        await firstBatch.wait()
        await document.stop()
        await execution.value

        #expect(document.statementResults.count == 2)
        guard case let .stopped(page?) = document.statementResults[0].state else {
            Issue.record("Expected a stopped first statement with partial rows.")
            return
        }
        #expect(page.rowCount == 1)
        #expect(
            document.statementResults[1].state
                == .skipped(
                    reason: AppCopy.current.text(
                        "执行已停止。",
                        "Execution stopped."
                    )
                )
        )
        #expect(await controlSession.cancelledConnectionID() == 41)
        await document.close()
    }

    @Test
    func resultRowLimitBoundsRowsAcrossStreamingBatches() async throws {
        let session = FailingBatchQuerySession(
            failingStatementIndex: .max,
            resultBatches: [
                makeRows(in: 0..<2),
                makeRows(in: 2..<5),
            ]
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )

        await document.execute(
            try await executionPlan(for: "SELECT value FROM sample;"),
            options: QueryExecutionOptions(
                statementTimeout: nil,
                maximumResultRows: 3
            )
        )

        guard case let .completed(page) = document.executionState else {
            Issue.record("Expected a completed limited result.")
            return
        }
        #expect(page.rowCount == 3)
        #expect(page.row(at: 0)?.values == [.text("0")])
        #expect(page.row(at: 2)?.values == [.text("2")])
        #expect(page.row(at: 3) == nil)
        #expect(await session.requestedMaximumRows() == [3])
        await document.close()
    }

    @Test
    func unlimitedResultRowsPreserveEveryStreamingBatch() async throws {
        let session = FailingBatchQuerySession(
            failingStatementIndex: .max,
            resultBatches: [
                makeRows(in: 0..<2),
                makeRows(in: 2..<5),
            ]
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: SingleQuerySessionFactory(session: session)
        )

        await document.execute(
            try await executionPlan(for: "SELECT value FROM sample;"),
            options: .unlimited
        )

        guard case let .completed(page) = document.executionState else {
            Issue.record("Expected a completed unlimited result.")
            return
        }
        #expect(page.rowCount == 5)
        #expect(page.row(at: 4)?.values == [.text("4")])
        await document.close()
    }

    @Test
    func statementTimeoutKillsServerQueryAndSkipsLaterStatements() async throws {
        let release = QueryTestSignal()
        let firstBatch = QueryTestSignal()
        let querySession = ControlledQuerySession(
            role: .query,
            release: release,
            firstBatch: firstBatch
        )
        let controlSession = ControlledQuerySession(
            role: .control,
            release: release,
            firstBatch: firstBatch
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: QuerySessionSequenceFactory(
                sessions: [querySession, controlSession]
            )
        )

        await document.execute(
            try await executionPlan(for: "SELECT 1;\nSELECT 2;"),
            options: QueryExecutionOptions(
                statementTimeout: .zero,
                maximumResultRows: nil
            )
        )

        guard case let .failed(message, _) = document.executionState else {
            Issue.record("Expected the query to time out.")
            return
        }
        #expect(
            message == AppCopy.current.text("查询超时。", "Query timed out.")
        )
        #expect(await controlSession.cancelledConnectionID() == 41)
        #expect(await controlSession.wasClosed())
        #expect(
            document.statementResults[1].state
                == .skipped(
                    reason: AppCopy.current.text(
                        "由于语句 1 超时，已跳过。",
                        "Skipped because Statement 1 timed out."
                    )
                )
        )
        await document.close()
    }

    @Test
    func failedServerCancellationRequiresAnExplicitDisconnect() async throws {
        let release = QueryTestSignal()
        let firstBatch = QueryTestSignal()
        let querySession = ControlledQuerySession(
            role: .query,
            release: release,
            firstBatch: firstBatch
        )
        let controlSession = ControlledQuerySession(
            role: .control,
            release: release,
            firstBatch: firstBatch,
            failsCancellation: true
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: makeConfiguration(database: nil),
            sessionFactory: QuerySessionSequenceFactory(
                sessions: [querySession, controlSession]
            )
        )

        let target = try executionTarget(for: "SELECT 1")
        let execution = Task { await document.execute(target) }
        await firstBatch.wait()
        await document.stop()

        #expect(document.cancellationFailureMessage != nil)
        #expect(!(await querySession.wasClosed()))

        await document.disconnectAfterCancellationFailure()
        await execution.value
        #expect(await querySession.wasClosed())
        #expect(document.transactionState == .disconnected)
        #expect(document.cancellationFailureMessage == nil)
    }

    @Test
    func queryExecutionContextSupportsAllDatabaseProducts() async {
        for product in DatabaseProduct.allCases {
            let document = WorkspaceQueryDocumentModel(
                title: product.rawValue,
                configuration: DatabaseConnectionConfiguration(
                    databaseProduct: product,
                    host: "127.0.0.1",
                    port: product.databaseType == .postgresql ? 5_432 : 3_306,
                    username: "reader",
                    password: nil,
                    database: "app",
                    tlsMode: .disabled
                ),
                sessionFactory: InMemoryWorkspaceSessionFactory(
                    databases: ["app", "analytics"],
                    schemasByDatabase: [
                        "analytics": ["tenant", "public"]
                    ]
                )
            )

            await document.selectDatabase("analytics")

            #expect(document.databaseName == "analytics")
            #expect(document.currentConnectionConfiguration.database == "analytics")
            #expect(
                document.currentConnectionConfiguration.databaseProduct
                    == product
            )
            if product == .postgresql {
                #expect(document.availableSchemas == ["tenant", "public"])
                #expect(document.schemaName == "public")
                await document.selectSchema("tenant")
                #expect(document.schemaName == "tenant")
            } else {
                #expect(document.availableSchemas.isEmpty)
                #expect(document.schemaName == nil)
            }
        }
    }

    @Test
    func reconnectKeepsDraftAndUsesTheReplacementConfiguration() async throws {
        let factory = RecordingQuerySessionFactory()
        let original = makeConfiguration(database: "old_database")
        let replacement = DatabaseConnectionConfiguration(
            host: "192.168.0.8",
            port: 3307,
            username: "reader",
            password: "new-secret",
            database: "new_database",
            tlsMode: .required
        )
        let document = WorkspaceQueryDocumentModel(
            title: "Query 1",
            configuration: original,
            sessionFactory: factory
        )
        document.sql = "SELECT 1"

        await document.execute(try executionTarget(for: document.sql))
        await document.replaceConnectionConfiguration(
            replacement,
            availableDatabases: ["new_database"]
        )
        await document.execute(try executionTarget(for: document.sql))

        #expect(document.sql == "SELECT 1")
        #expect(document.databaseName == "new_database")
        #expect(await factory.configurations == [original, replacement])
        await document.close()
    }

    private func makeConfiguration(database: String?)
        -> DatabaseConnectionConfiguration
    {
        DatabaseConnectionConfiguration(
            host: "127.0.0.1",
            port: 3306,
            username: "root",
            password: "secret",
            database: database,
            tlsMode: .disabled
        )
    }

    private func executionTarget(for sql: String) throws -> SQLExecutionTarget {
        try SQLExecutionTargetResolver.resolve(
            .all,
            source: SQLSourceSnapshot(
                revision: SQLSourceRevision(1),
                text: sql
            ),
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: nil
        )
    }

    private func executionPlan(for sql: String) async throws
        -> SQLExecutionBatchPlan
    {
        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(1),
            text: sql
        )
        let snapshot = try await SQLStructuralParser().parse(source)
        let target = try SQLExecutionTargetResolver.resolve(
            .all,
            source: source,
            selectedRange: NSRange(location: 0, length: 0),
            parseSnapshot: snapshot
        )
        return try SQLExecutionBatchPreflight.makePlan(
            target: target,
            parseSnapshot: snapshot
        )
    }

    private func makeRows(
        in range: Range<Int>
    ) -> [WorkspaceDatabaseDataRow] {
        range.map {
            WorkspaceDatabaseDataRow(
                id: $0,
                values: [.text(String($0))]
            )
        }
    }
}

private actor RecordingQuerySessionFactory: WorkspaceSessionFactory {
    private(set) var configurations: [DatabaseConnectionConfiguration] = []

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        configurations.append(configuration)
        return InMemoryWorkspaceSession(databases: ["new_database"])
    }
}

private actor QuerySessionSequenceFactory: WorkspaceSessionFactory {
    private var sessions: [any WorkspaceSession]

    init(sessions: [any WorkspaceSession]) {
        self.sessions = sessions
    }

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        sessions.removeFirst()
    }
}

private struct SingleQuerySessionFactory: WorkspaceSessionFactory {
    let session: any WorkspaceSession

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        session
    }
}

private actor FailingBatchQuerySession: WorkspaceSession {
    private let failingStatementIndex: Int
    private let resultBatches: [[WorkspaceDatabaseDataRow]]?
    private var isConnected = false
    private var statements: [String] = []
    private var reads: [String] = []
    private var writes: [String] = []
    private var maximumRows: [Int?] = []
    private var transactionState = WorkspaceQueryTransactionState.disconnected

    init(
        failingStatementIndex: Int,
        resultBatches: [[WorkspaceDatabaseDataRow]]? = nil
    ) {
        self.failingStatementIndex = failingStatementIndex
        self.resultBatches = resultBatches
    }

    func connect() async throws {
        isConnected = true
        transactionState = .autoCommit
    }

    func isConnected() async -> Bool {
        isConnected
    }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        return []
    }

    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        try requireConnection()
        return []
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw WorkspaceSessionError.metadataUnavailable(object: object.name)
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        try requireConnection()
        return []
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        throw WorkspaceSessionError.queryUnavailable
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func connectionID() async throws -> Int {
        try requireConnection()
        return 42
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws
            -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        reads.append(sql)
        return try await execute(sql, onBatch: onBatch)
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws
            -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        self.maximumRows.append(maximumRows)
        return try await executeReadOnlyQuery(
            sql,
            database: database,
            onBatch: onBatch
        )
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws
            -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        writes.append(sql)
        let result = try await execute(sql, onBatch: onBatch)
        transactionState = try transactionState.afterSuccessfulStatement(kind)
        return WorkspaceQueryExecutionResult(
            columns: result.columns,
            rowCount: result.rowCount,
            transactionState: transactionState
        )
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws
            -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        self.maximumRows.append(maximumRows)
        return try await executeStatement(
            sql,
            kind: kind,
            database: database,
            onBatch: onBatch
        )
    }

    private func execute(
        _ sql: String,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws
            -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try requireConnection()
        let statementIndex = statements.count
        statements.append(sql)
        if statementIndex == failingStatementIndex {
            throw WorkspaceSessionError.queryUnavailable
        }
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        if let resultBatches {
            for rows in resultBatches {
                try await onBatch(
                    WorkspaceDatabaseDataBatch(
                        columns: columns,
                        rows: rows
                    )
                )
            }
            return WorkspaceQueryExecutionResult(
                columns: columns,
                rowCount: resultBatches.reduce(0) { $0 + $1.count }
            )
        }
        try await onBatch(
            WorkspaceDatabaseDataBatch(
                columns: columns,
                rows: [
                    WorkspaceDatabaseDataRow(
                        id: 0,
                        values: [.text("\(statementIndex + 1)")]
                    )
                ]
            )
        )
        return WorkspaceQueryExecutionResult(columns: columns, rowCount: 1)
    }

    func cancelQuery(connectionID: Int) async throws {
        try requireConnection()
    }

    func close() async {
        isConnected = false
        transactionState = .disconnected
    }

    func executedStatements() -> [String] {
        statements
    }

    func readOnlyStatements() -> [String] {
        reads
    }

    func writableStatements() -> [String] {
        writes
    }

    func requestedMaximumRows() -> [Int?] {
        maximumRows
    }

    func wasClosed() -> Bool {
        !isConnected
    }

    private func requireConnection() throws {
        guard isConnected else { throw WorkspaceSessionError.notConnected }
    }
}

private actor ControlledQuerySession: WorkspaceSession {
    enum Role: Sendable {
        case query
        case control
    }

    private let role: Role
    private let release: QueryTestSignal
    private let firstBatch: QueryTestSignal
    private let failsCancellation: Bool
    private var isConnected = false
    private var closed = false
    private var cancelledID: Int?

    init(
        role: Role,
        release: QueryTestSignal,
        firstBatch: QueryTestSignal,
        failsCancellation: Bool = false
    ) {
        self.role = role
        self.release = release
        self.firstBatch = firstBatch
        self.failsCancellation = failsCancellation
    }

    func connect() async throws {
        isConnected = true
    }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        return []
    }

    func fetchObjects(in database: String) async throws
        -> [WorkspaceDatabaseObject]
    {
        try requireConnection()
        return []
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw WorkspaceSessionError.metadataUnavailable(object: object.name)
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        try requireConnection()
        return []
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        throw WorkspaceSessionError.queryUnavailable
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func connectionID() async throws -> Int {
        try requireConnection()
        return 41
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws
            -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try requireConnection()
        guard role == .query else {
            throw WorkspaceSessionError.queryUnavailable
        }
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        try await onBatch(
            WorkspaceDatabaseDataBatch(
                columns: columns,
                rows: [
                    WorkspaceDatabaseDataRow(
                        id: 0,
                        values: [.text("first")]
                    )
                ]
            )
        )
        await firstBatch.signal()
        await release.wait()
        throw CancellationError()
    }

    func cancelQuery(connectionID: Int) async throws {
        try requireConnection()
        guard role == .control else {
            throw WorkspaceSessionError.queryUnavailable
        }
        guard !failsCancellation else {
            throw WorkspaceSessionError.queryUnavailable
        }
        cancelledID = connectionID
        await release.signal()
    }

    func close() async {
        closed = true
        isConnected = false
        await release.signal()
    }

    func cancelledConnectionID() -> Int? {
        cancelledID
    }

    func wasClosed() -> Bool {
        closed
    }

    private func requireConnection() throws {
        guard isConnected else { throw WorkspaceSessionError.notConnected }
    }
}

private actor QueryTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
