import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceQueryDocumentModel: Identifiable {
    let id: UUID
    private(set) var title: String
    private(set) var savedQueryID: SavedQuery.ID?
    var sql = "" {
        didSet {
            guard sql != oldValue else { return }
            recoverableContentDidChange(id)
        }
    }
    var selectedRange = NSRange(location: 0, length: 0)
    var databaseName: String? {
        didSet {
            guard databaseName != oldValue else { return }
            availableSchemas = []
            schemaName = nil
            recoverableContentDidChange(id)
        }
    }
    private(set) var availableSchemas: [String] = []
    private(set) var schemaName: String?
    private(set) var isLoadingSchemas = false
    var resultRowLimit: QueryResultRowLimit
    private(set) var isSaving = false
    private(set) var executionState = WorkspaceQueryExecutionState.idle
    private(set) var elapsedSeconds = 0.0
    private(set) var statementResults: [WorkspaceStatementResult] = []
    private(set) var transactionState = WorkspaceQueryTransactionState.disconnected
    private(set) var cancellationFailureMessage: String?
    var selectedStatementResultIndex = 0

    var isDirty: Bool {
        requiresSavingAsNewQuery
            || sql != persistedSQL
            || databaseName != persistedDatabaseName
    }

    var canSave: Bool {
        !isSaving && (savedQueryID == nil || isDirty)
    }

    var databaseType: DatabaseType {
        configuration.databaseType
    }

    var currentConnectionConfiguration: DatabaseConnectionConfiguration {
        configuration.selecting(database: databaseName)
    }

    var canChangeExecutionContext: Bool {
        !executionState.isRunning
            && transactionState != .inTransaction
            && cancellationFailureMessage == nil
    }

    var preflightCloseFailureMessage: String? {
        if isSaving {
            return WorkspaceQueryDocumentError.saveInProgress
                .localizedDescription
        }
        if executionState.isRunning {
            return WorkspaceQueryDocumentError.executionInProgress
                .localizedDescription
        }
        if cancellationFailureMessage != nil {
            return WorkspaceQueryDocumentError.cancellationRequiresDisconnect
                .localizedDescription
        }
        return nil
    }

    private var configuration: DatabaseConnectionConfiguration
    private let sessionFactory: any WorkspaceSessionFactory
    private let recoverableContentDidChange: @MainActor (UUID) -> Void
    private var session: (any WorkspaceSession)?
    private var executionID: UUID?
    private var activeConnectionID: Int?
    private var activeStatementIndex: Int?
    private var executionStartedAt: ContinuousClock.Instant?
    private var statementStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var statementTimeoutTask: Task<Void, Never>?
    private var schemaLoadID: UUID?
    private var persistedSQL: String
    private var persistedDatabaseName: String?
    private var requiresSavingAsNewQuery = false

    init(
        id: UUID = UUID(),
        title: String,
        configuration: DatabaseConnectionConfiguration,
        sessionFactory: any WorkspaceSessionFactory,
        savedQuery: SavedQuery? = nil,
        recoverableDraft: RecoverableDraft? = nil,
        restorationState: WorkspaceQueryDocumentRestorationState? = nil,
        resultRowLimit: QueryResultRowLimit? = nil,
        recoverableContentDidChange: @escaping @MainActor (UUID) -> Void = {
            _ in
        }
    ) {
        precondition(
            [savedQuery != nil, recoverableDraft != nil, restorationState != nil]
                .count(where: { $0 }) <= 1
        )
        self.id = recoverableDraft?.id ?? restorationState?.id ?? id
        self.configuration = configuration
        self.sessionFactory = sessionFactory
        self.recoverableContentDidChange = recoverableContentDidChange
        self.resultRowLimit = resultRowLimit
            ?? restorationState?.resultRowLimit
            ?? ApplicationPreferences.shared.queryResultRowLimit
        if let recoverableDraft {
            self.title = title
            savedQueryID = nil
            sql = recoverableDraft.sql
            databaseName = recoverableDraft.defaultDatabase
            persistedSQL = ""
            persistedDatabaseName = configuration.database
            requiresSavingAsNewQuery = true
        } else if let savedQuery {
            self.title = savedQuery.name
            savedQueryID = savedQuery.id
            sql = savedQuery.sql
            databaseName = savedQuery.defaultDatabase
            persistedSQL = savedQuery.sql
            persistedDatabaseName = savedQuery.defaultDatabase
        } else if let restorationState {
            self.title = restorationState.title
            savedQueryID = nil
            databaseName = restorationState.defaultDatabase
            persistedSQL = ""
            persistedDatabaseName = restorationState.defaultDatabase
        } else {
            self.title = title
            savedQueryID = nil
            databaseName = configuration.database
            persistedSQL = ""
            persistedDatabaseName = configuration.database
        }
    }

    func beginSaving() -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        return true
    }

    func finishSaving(_ query: SavedQuery?) {
        defer { isSaving = false }
        guard let query else { return }
        title = query.name
        savedQueryID = query.id
        persistedSQL = query.sql
        persistedDatabaseName = query.defaultDatabase
        requiresSavingAsNewQuery = false
    }

    func applySavedQueryMetadata(_ query: SavedQuery) {
        guard savedQueryID == query.id else { return }
        title = query.name
        let previousPersistedDatabaseName = persistedDatabaseName
        persistedDatabaseName = query.defaultDatabase
        if databaseName == previousPersistedDatabaseName {
            databaseName = query.defaultDatabase
        }
    }

    func reconcile(with query: SavedQuery) -> Bool {
        guard savedQueryID == query.id else { return false }
        title = query.name
        guard hasExternalContentChange(from: query) else { return false }
        guard !isDirty else { return true }
        reload(from: query)
        return false
    }

    func hasUnresolvedExternalChange(from query: SavedQuery) -> Bool {
        isDirty && hasExternalContentChange(from: query)
    }

    func ignoreExternalChange(from query: SavedQuery) {
        guard savedQueryID == query.id else { return }
        title = query.name
        persistedSQL = query.sql
        persistedDatabaseName = query.defaultDatabase
        requiresSavingAsNewQuery = false
    }

    func reload(from query: SavedQuery) {
        guard savedQueryID == query.id else { return }
        title = query.name
        sql = query.sql
        databaseName = query.defaultDatabase
        persistedSQL = query.sql
        persistedDatabaseName = query.defaultDatabase
        requiresSavingAsNewQuery = false
    }

    func detachFromSavedQuery() {
        guard savedQueryID != nil else { return }
        savedQueryID = nil
        requiresSavingAsNewQuery = true
    }

    private func hasExternalContentChange(from query: SavedQuery) -> Bool {
        savedQueryID == query.id
            && (query.sql != persistedSQL
                || query.defaultDatabase != persistedDatabaseName)
    }

    func execute(
        _ target: SQLExecutionTarget,
        options: QueryExecutionOptions = .unlimited
    ) async {
        guard !executionState.isRunning else { return }
        statementResults = []
        selectedStatementResultIndex = 0

        let statement: String
        do {
            statement = try WorkspaceReadOnlyQueryValidator.validate(
                target.sql
            )
        } catch {
            statementResults = []
            executionState = .failed(
                message: error.localizedDescription,
                page: nil
            )
            return
        }

        let resultStore: WorkspaceQueryResultStore
        do {
            resultStore = try await WorkspaceQueryResultStore.makeTemporary()
        } catch {
            executionState = .failed(
                message: error.localizedDescription,
                page: nil
            )
            return
        }

        let executionID = UUID()
        let executionStatement = SQLExecutionStatement(
            index: 0,
            source: target.source,
            range: target.range,
            kind: .read
        )
        self.executionID = executionID
        activeConnectionID = nil
        activeStatementIndex = 0
        executionStartedAt = .now
        statementStartedAt = .now
        elapsedSeconds = 0
        executionState = .running(nil)
        statementResults = [
            WorkspaceStatementResult(
                statement: executionStatement,
                state: .running(nil),
                elapsedSeconds: 0
            )
        ]

        do {
            let session = try await connectedSession(for: executionID)
            guard self.executionID == executionID else { return }
            activeConnectionID = try await session.connectionID()
            guard self.executionID == executionID else { return }
            scheduleStatementTimeout(
                options.statementTimeout,
                executionID: executionID,
                statementIndex: 0
            )

            let onBatch: @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void = {
                [weak self] batch in
                guard let self else { throw CancellationError() }
                try await self.append(
                    batch,
                    to: resultStore,
                    executionID: executionID,
                    statementIndex: 0,
                    maximumResultRows: options.maximumResultRows
                )
            }
            let result = if transactionState == .inTransaction {
                try await session.executeStatement(
                    statement,
                    kind: .read,
                    database: databaseName,
                    maximumRows: options.maximumResultRows,
                    onBatch: onBatch
                )
            } else {
                try await session.executeReadOnlyQuery(
                    statement,
                    database: databaseName,
                    maximumRows: options.maximumResultRows,
                    onBatch: onBatch
                )
            }
            guard self.executionID == executionID else { return }
            cancelStatementTimeout()
            transactionState = result.transactionState

            let page = WorkspaceQueryResultPage(
                columns: result.columns,
                store: resultStore,
                rowCount: resultStore.rowCount
            )
            self.executionID = nil
            activeConnectionID = nil
            activeStatementIndex = nil
            updateElapsedTime()
            executionState = .completed(page)
            updateStatementResult(at: 0, state: .completed(page))
        } catch is CancellationError {
            guard self.executionID == executionID else { return }
            cancelStatementTimeout()
            self.executionID = nil
            activeConnectionID = nil
            activeStatementIndex = nil
            updateElapsedTime()
            executionState = .stopped(executionState.page)
            updateStatementResult(at: 0, state: executionState)
        } catch {
            if let session {
                await markDisconnectedIfNeeded(session)
            }
            guard self.executionID == executionID else { return }
            cancelStatementTimeout()
            self.executionID = nil
            activeConnectionID = nil
            activeStatementIndex = nil
            updateElapsedTime()
            executionState = .failed(
                message: error.localizedDescription,
                page: executionState.page
            )
            updateStatementResult(at: 0, state: executionState)
        }
    }

    func execute(
        _ plan: SQLExecutionBatchPlan,
        policy: SQLExecutionPolicy = .readOnly,
        options: QueryExecutionOptions = .unlimited
    ) async {
        guard !executionState.isRunning else { return }

        do {
            if plan.requiresWriteAccess, !policy.allowsWrites {
                throw plan.containsUnclassifiedStatement
                    ? SQLExecutionPolicyError.unclassifiedStatement
                    : SQLExecutionPolicyError.safetyLockEnabled
            }
            for statement in plan.statements {
                _ = try WorkspaceReadOnlyQueryValidator.validate(
                    statement.sql,
                    policy: statement.kind.isTransaction
                        ? .writesAllowed
                        : policy
                )
            }
        } catch {
            statementResults = []
            selectedStatementResultIndex = 0
            executionState = .failed(
                message: error.localizedDescription,
                page: nil
            )
            return
        }

        let executionID = UUID()
        self.executionID = executionID
        activeConnectionID = nil
        activeStatementIndex = nil
        executionStartedAt = .now
        statementStartedAt = nil
        elapsedSeconds = 0
        selectedStatementResultIndex = 0
        statementResults = plan.statements.map {
            WorkspaceStatementResult(
                statement: $0,
                state: .idle,
                elapsedSeconds: 0
            )
        }
        executionState = .running(nil)

        do {
            let session = try await connectedSession(for: executionID)
            guard self.executionID == executionID else { return }
            activeConnectionID = try await session.connectionID()
            guard self.executionID == executionID else { return }

            for statement in plan.statements {
                guard self.executionID == executionID else {
                    throw CancellationError()
                }
                try await executeStatement(
                    statement,
                    session: session,
                    executionID: executionID,
                    policy: policy,
                    options: options
                )
            }

            guard self.executionID == executionID else { return }
            cancelStatementTimeout()
            self.executionID = nil
            activeConnectionID = nil
            activeStatementIndex = nil
            statementStartedAt = nil
            updateElapsedTime()
            executionState = statementResults.last?.state ?? .idle
        } catch is CancellationError {
            guard self.executionID == executionID else { return }
            cancelStatementTimeout()
            finishStoppedExecution()
        } catch {
            if let session {
                await markDisconnectedIfNeeded(session)
            }
            guard self.executionID == executionID else { return }
            cancelStatementTimeout()
            finishFailedExecution(error)
        }
    }

    func reportExecutionTargetFailure(_ error: Error) {
        guard !executionState.isRunning else { return }
        statementResults = []
        selectedStatementResultIndex = 0
        executionState = .failed(
            message: error.localizedDescription,
            page: nil
        )
    }

    func dismissResults() {
        guard !executionState.isRunning else { return }
        executionState = .idle
        statementResults = []
        selectedStatementResultIndex = 0
        elapsedSeconds = 0
        executionStartedAt = nil
    }

    func executeTransactionCommand(
        _ command: WorkspaceQueryTransactionCommand
    ) async {
        guard !executionState.isRunning else { return }
        switch command {
        case .begin where transactionState == .inTransaction:
            return
        case .commit where transactionState != .inTransaction,
             .rollback where transactionState != .inTransaction:
            return
        case .begin, .commit, .rollback:
            break
        }

        let source = SQLSourceSnapshot(
            revision: SQLSourceRevision(0),
            text: command.sql
        )
        let range = SQLSourceRange(
            location: 0,
            length: (command.sql as NSString).length
        )
        let target = SQLExecutionTarget(
            kind: .document,
            source: source,
            range: range
        )
        await execute(
            SQLExecutionBatchPlan(
                target: target,
                statements: [
                    SQLExecutionStatement(
                        index: 0,
                        source: source,
                        range: range,
                        kind: .transaction(command.operation)
                    )
                ]
            )
        )
    }

    func stop() async {
        guard executionState.isRunning else { return }
        cancelStatementTimeout()
        let page = executionState.page
        let statementIndex = activeStatementIndex
        let connectionID = activeConnectionID
        executionID = nil
        activeConnectionID = nil
        activeStatementIndex = nil
        updateElapsedTime()
        executionState = .stopped(page)
        if let statementIndex {
            updateStatementResult(at: statementIndex, state: .stopped(page))
            markStatementsSkipped(
                after: statementIndex,
                reason: AppCopy.current.text("执行已停止。", "Execution stopped.")
            )
        }

        guard let connectionID else {
            if let session {
                cancellationFailureMessage =
                    AppCopy.current.text(
                        "无法确定要取消的服务器查询。请断开此会话以确保查询停止；所有活动事务都将丢失。",
                        "The server query could not be identified for cancellation. Disconnect this session to guarantee it stops; any active transaction will be lost."
                    )
                await markDisconnectedIfNeeded(session)
            } else {
                transactionState = .disconnected
            }
            return
        }

        if let error = await serverCancellationError(
            connectionID: connectionID
        ) {
            cancellationFailureMessage =
                AppCopy.current.text(
                    "服务器未取消查询：\(error.localizedDescription) 请断开此会话以确保查询停止；所有活动事务都将丢失。",
                    "The server did not cancel the query: \(error.localizedDescription) Disconnect this session to guarantee it stops; any active transaction will be lost."
                )
        }
    }

    func disconnectAfterCancellationFailure() async {
        guard cancellationFailureMessage != nil else { return }
        if let session {
            self.session = nil
            await session.close()
        }
        transactionState = .disconnected
        cancellationFailureMessage = nil
    }

    @discardableResult
    func close() async -> WorkspaceQueryDocumentCloseResult {
        if let preflightCloseFailureMessage {
            return .failed(message: preflightCloseFailureMessage)
        }

        if transactionState == .inTransaction, let session {
            do {
                let result = try await session.executeStatement(
                    WorkspaceQueryTransactionCommand.rollback.sql,
                    kind: .transaction(.rollback),
                    database: databaseName
                ) { _ in }
                guard result.transactionState != .inTransaction else {
                    throw WorkspaceQueryDocumentError.rollbackDidNotEndTransaction
                }
                transactionState = result.transactionState
            } catch {
                await markDisconnectedIfNeeded(session)
                if transactionState == .inTransaction {
                    return .failed(message: error.localizedDescription)
                }
            }
        }

        executionID = nil
        activeConnectionID = nil
        activeStatementIndex = nil
        cancelStatementTimeout()
        if let session {
            self.session = nil
            await session.close()
        }
        transactionState = .disconnected
        return .closed
    }

    func closeForWorkspaceShutdown() async {
        guard case .failed = await close() else { return }
        executionID = nil
        activeConnectionID = nil
        activeStatementIndex = nil
        cancelStatementTimeout()
        if let session {
            self.session = nil
            await session.close()
        }
        transactionState = .disconnected
        cancellationFailureMessage = nil
    }

    func replaceConnectionConfiguration(
        _ configuration: DatabaseConnectionConfiguration,
        availableDatabases: [String]
    ) async {
        if self.configuration != configuration, let session {
            self.session = nil
            transactionState = .disconnected
            cancellationFailureMessage = nil
            await session.close()
        }
        self.configuration = configuration

        if let databaseName {
            if savedQueryID == nil,
               !requiresSavingAsNewQuery,
               !availableDatabases.contains(databaseName)
            {
                self.databaseName = configuration.database.flatMap {
                    availableDatabases.contains($0) ? $0 : nil
                }
            }
        } else if let defaultDatabase = configuration.database,
                  availableDatabases.contains(defaultDatabase)
        {
            databaseName = defaultDatabase
        }
        await refreshSchemas()
    }

    func selectDatabase(_ database: String?) async {
        guard canChangeExecutionContext, databaseName != database else { return }
        await closeSessionForExecutionContextChange()
        databaseName = database
        await refreshSchemas()
    }

    func selectSchema(_ schema: String?) async {
        guard canChangeExecutionContext else { return }
        guard configuration.databaseType == .postgresql else { return }
        if let schema {
            guard availableSchemas.contains(schema) else { return }
        }
        guard schemaName != schema else { return }
        await closeSessionForExecutionContextChange()
        schemaName = schema
    }

    func refreshSchemas() async {
        guard configuration.databaseType == .postgresql,
              let databaseName
        else {
            schemaLoadID = nil
            availableSchemas = []
            schemaName = nil
            isLoadingSchemas = false
            return
        }

        let loadID = UUID()
        schemaLoadID = loadID
        isLoadingSchemas = true
        let metadataSession = await sessionFactory.makeSession(
            configuration: currentConnectionConfiguration
        )
        do {
            try await metadataSession.connect()
            let schemas = try await metadataSession.fetchSchemas(
                in: databaseName
            )
            await metadataSession.close()
            guard schemaLoadID == loadID, self.databaseName == databaseName else {
                return
            }
            availableSchemas = schemas
            if !schemas.contains(schemaName ?? "") {
                schemaName = schemas.contains("public") ? "public" : schemas.first
            }
            isLoadingSchemas = false
        } catch is CancellationError {
            await metadataSession.close()
        } catch {
            await metadataSession.close()
            guard schemaLoadID == loadID, self.databaseName == databaseName else {
                return
            }
            availableSchemas = []
            schemaName = nil
            isLoadingSchemas = false
        }
    }

    private func connectedSession(
        for executionID: UUID
    ) async throws -> any WorkspaceSession {
        guard self.executionID == executionID else {
            throw CancellationError()
        }
        guard cancellationFailureMessage == nil else {
            throw WorkspaceQueryDocumentError.cancellationRequiresDisconnect
        }
        if let session { return session }
        let newSession = await sessionFactory.makeSession(
            configuration: currentConnectionConfiguration
        )
        do {
            try await newSession.connect()
            try await newSession.applyQueryContext(
                WorkspaceQueryContext(
                    databaseName: databaseName,
                    schemaName: configuration.databaseType == .postgresql
                        ? schemaName
                        : nil
                )
            )
        } catch {
            await newSession.close()
            throw error
        }
        guard self.executionID == executionID else {
            await newSession.close()
            throw CancellationError()
        }
        session = newSession
        transactionState = .autoCommit
        return newSession
    }

    private func closeSessionForExecutionContextChange() async {
        guard let session else { return }
        self.session = nil
        transactionState = .disconnected
        cancellationFailureMessage = nil
        await session.close()
    }

    private func append(
        _ batch: WorkspaceDatabaseDataBatch,
        to store: WorkspaceQueryResultStore,
        executionID: UUID,
        statementIndex: Int,
        maximumResultRows: Int?
    ) async throws {
        guard self.executionID == executionID else {
            throw CancellationError()
        }
        let rows: [WorkspaceDatabaseDataRow]
        if let maximumResultRows {
            let remaining = max(0, maximumResultRows - store.rowCount)
            rows = Array(batch.rows.prefix(remaining))
        } else {
            rows = batch.rows
        }
        try await store.append(rows)
        guard self.executionID == executionID else {
            throw CancellationError()
        }
        let page = WorkspaceQueryResultPage(
            columns: batch.columns,
            store: store,
            rowCount: store.rowCount
        )
        executionState = .running(page)
        updateStatementResult(at: statementIndex, state: .running(page))
        updateElapsedTime()
    }

    private func executeStatement(
        _ statement: SQLExecutionStatement,
        session: any WorkspaceSession,
        executionID: UUID,
        policy: SQLExecutionPolicy,
        options: QueryExecutionOptions
    ) async throws {
        let store = try await WorkspaceQueryResultStore.makeTemporary()
        activeStatementIndex = statement.index
        selectedStatementResultIndex = statement.index
        statementStartedAt = .now
        executionState = .running(nil)
        updateStatementResult(at: statement.index, state: .running(nil))
        scheduleStatementTimeout(
            options.statementTimeout,
            executionID: executionID,
            statementIndex: statement.index
        )

        let onBatch: @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void = {
            [weak self] batch in
            guard let self else { throw CancellationError() }
            try await self.append(
                batch,
                to: store,
                executionID: executionID,
                statementIndex: statement.index,
                maximumResultRows: options.maximumResultRows
            )
        }
        let result = if statement.kind == .read
            && transactionState != .inTransaction
        {
            try await session.executeReadOnlyQuery(
                statement.sql,
                database: databaseName,
                maximumRows: options.maximumResultRows,
                onBatch: onBatch
            )
        } else if policy.allowsWrites || statement.kind.isTransaction
            || transactionState == .inTransaction
        {
            try await session.executeStatement(
                statement.sql,
                kind: statement.kind,
                database: databaseName,
                maximumRows: options.maximumResultRows,
                onBatch: onBatch
            )
        } else {
            try await session.executeReadOnlyQuery(
                statement.sql,
                database: databaseName,
                maximumRows: options.maximumResultRows,
                onBatch: onBatch
            )
        }
        guard self.executionID == executionID else {
            throw CancellationError()
        }
        cancelStatementTimeout()
        transactionState = result.transactionState
        let page = WorkspaceQueryResultPage(
            columns: result.columns,
            store: store,
            rowCount: store.rowCount
        )
        executionState = .running(page)
        updateStatementResult(at: statement.index, state: .completed(page))
    }

    private func finishStoppedExecution() {
        let statementIndex = activeStatementIndex
        let page = statementIndex.flatMap { statementResults[safe: $0]?.state.page }
        executionID = nil
        activeConnectionID = nil
        activeStatementIndex = nil
        updateElapsedTime()
        executionState = .stopped(page)
        if let statementIndex {
            updateStatementResult(at: statementIndex, state: .stopped(page))
            markStatementsSkipped(
                after: statementIndex,
                reason: AppCopy.current.text("执行已停止。", "Execution stopped.")
            )
        }
    }

    private func finishFailedExecution(_ error: Error) {
        let statementIndex = activeStatementIndex
        let page = statementIndex.flatMap { statementResults[safe: $0]?.state.page }
        executionID = nil
        activeConnectionID = nil
        activeStatementIndex = nil
        updateElapsedTime()
        executionState = .failed(
            message: error.localizedDescription,
            page: page
        )
        if let statementIndex {
            updateStatementResult(at: statementIndex, state: executionState)
            markStatementsSkipped(
                after: statementIndex,
                reason: AppCopy.current.text(
                    "由于语句 \(statementIndex + 1) 失败，已跳过：\(error.localizedDescription)",
                    "Skipped because Statement \(statementIndex + 1) failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func updateStatementResult(
        at index: Int,
        state: WorkspaceQueryExecutionState
    ) {
        guard statementResults.indices.contains(index) else { return }
        statementResults[index].state = state
        if let statementStartedAt {
            statementResults[index].elapsedSeconds = statementStartedAt
                .duration(to: .now).seconds
        }
    }

    private func markStatementsSkipped(after index: Int, reason: String) {
        guard index + 1 < statementResults.count else { return }
        for skippedIndex in (index + 1)..<statementResults.count {
            statementResults[skippedIndex].state = .skipped(reason: reason)
        }
    }

    private func updateElapsedTime() {
        guard let executionStartedAt else { return }
        elapsedSeconds = executionStartedAt.duration(to: .now).seconds
    }

    private func markDisconnectedIfNeeded(
        _ session: any WorkspaceSession
    ) async {
        let isConnected = await session.isConnected()
        guard self.session === session, !isConnected else { return }
        self.session = nil
        transactionState = .disconnected
    }

    private func scheduleStatementTimeout(
        _ timeout: Duration?,
        executionID: UUID,
        statementIndex: Int
    ) {
        cancelStatementTimeout()
        guard let timeout else { return }
        statementTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.timeOutStatement(
                executionID: executionID,
                statementIndex: statementIndex
            )
        }
    }

    private func cancelStatementTimeout() {
        statementTimeoutTask?.cancel()
        statementTimeoutTask = nil
    }

    private func timeOutStatement(
        executionID: UUID,
        statementIndex: Int
    ) async {
        guard self.executionID == executionID,
              activeStatementIndex == statementIndex,
              executionState.isRunning
        else {
            return
        }

        let page = statementResults[safe: statementIndex]?.state.page
            ?? executionState.page
        let connectionID = activeConnectionID
        statementTimeoutTask = nil
        self.executionID = nil
        activeConnectionID = nil
        activeStatementIndex = nil
        updateElapsedTime()
        executionState = .failed(
            message: AppCopy.current.text("查询超时。", "Query timed out."),
            page: page
        )
        updateStatementResult(at: statementIndex, state: executionState)
        markStatementsSkipped(
            after: statementIndex,
            reason: AppCopy.current.text(
                "由于语句 \(statementIndex + 1) 超时，已跳过。",
                "Skipped because Statement \(statementIndex + 1) timed out."
            )
        )

        guard let connectionID else { return }
        if let error = await serverCancellationError(
            connectionID: connectionID
        ) {
            cancellationFailureMessage =
                AppCopy.current.text(
                    "服务器未取消已超时的查询：\(error.localizedDescription) 请断开此会话以确保查询停止；所有活动事务都将丢失。",
                    "The server did not cancel the timed-out query: \(error.localizedDescription) Disconnect this session to guarantee it stops; any active transaction will be lost."
                )
        }
    }

    private func serverCancellationError(
        connectionID: Int
    ) async -> Error? {
        let controlSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await controlSession.connect()
            try await controlSession.cancelQuery(connectionID: connectionID)
            await controlSession.close()
            return nil
        } catch {
            await controlSession.close()
            return error
        }
    }
}

private extension SQLStatementKind {
    var isTransaction: Bool {
        if case .transaction = self { true } else { false }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
