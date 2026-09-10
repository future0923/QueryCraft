import SwiftUI

struct WorkspaceQueryDocumentView: View {
    @Bindable var document: WorkspaceQueryDocumentModel
    let databases: [String]
    let schemaCatalog: WorkspaceSchemaCatalogSnapshot
    let safetyLock: WorkspaceSafetyLock
    let editorContext: WorkspaceQueryEditorContext
    let contentID: WorkspaceContentTabID
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let fetchResultDetails: @MainActor (
        WorkspaceDatabaseObjectSelection
    ) async throws -> WorkspaceDatabaseObjectDetails
    let applyResultChanges: @MainActor (
        WorkspaceDatabaseDataChangeSet
    ) async throws -> Void
    let updateResultInspectorContext:
        @MainActor (WorkspaceQueryResultInspectorContext) -> Void
    @State private var showsCancellationFailure = false
    @State private var showsDangerousExecutionConfirmation = false
    @State private var pendingDangerousExecution:
        PendingDangerousQueryExecution?
    @State private var preferences = ApplicationPreferences.shared

    private var languageService: WorkspaceSQLLanguageService {
        editorContext.languageService
    }

    private var commandCoordinator: WorkspaceQueryEditorCommandCoordinator {
        editorContext.commandCoordinator
    }

    private var completionService: WorkspaceSQLCompletionService {
        editorContext.completionService
    }

    private var settingsCopy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                VStack(spacing: 0) {
                    WorkspaceCodeEditQueryEditor(
                        text: $document.sql,
                        selectedRange: $document.selectedRange,
                        languageService: languageService,
                        commandCoordinator: commandCoordinator,
                        completionService: completionService
                    )

                    WorkspaceQueryEditorActionBar(
                        selectionOrCurrentStatementAvailability: languageService
                            .selectionOrCurrentStatementAvailability,
                        runAllAvailability: languageService.runAllAvailability,
                        isRunning: document.executionState.isRunning,
                        resultRowLimit: $document.resultRowLimit,
                        transactionState: document.transactionState,
                        requiresDisconnect: document.cancellationFailureMessage != nil,
                        databaseType: document.databaseType,
                        databases: databases,
                        selectedDatabase: document.databaseName,
                        schemas: document.availableSchemas,
                        selectedSchema: document.schemaName,
                        isLoadingSchemas: document.isLoadingSchemas,
                        canChangeExecutionContext:
                            document.canChangeExecutionContext,
                        selectDatabase: { database in
                            Task { await document.selectDatabase(database) }
                        },
                        selectSchema: { schema in
                            Task { await document.selectSchema(schema) }
                        },
                        runSelectionOrCurrentStatement: runSelectionOrCurrentStatement,
                        runAll: runAll,
                        stop: stop,
                        formatSelectionOrCurrentStatement: formatSelectionOrCurrentStatement,
                        formatDocument: formatDocument,
                        commitTransaction: commitTransaction,
                        rollbackTransaction: rollbackTransaction,
                        disconnectSession: disconnectSession
                    )
                }
                .frame(minHeight: 236, idealHeight: 456)

                ZStack {
                    Color(nsColor: .textBackgroundColor)

                    if document.executionState != .idle {
                        WorkspaceQueryResultView(
                            state: document.executionState,
                            statementResults: document.statementResults,
                            selectedStatementResultIndex: $document
                                .selectedStatementResultIndex,
                            elapsedSeconds: document.elapsedSeconds,
                            currentDatabase: document.databaseName,
                            databaseType: document.databaseType,
                            safetyLock: safetyLock,
                            contentID: contentID,
                            pendingChangesRegistry: pendingChangesRegistry,
                            fetchDetails: fetchResultDetails,
                            applyChanges: applyResultChanges,
                            dismiss: document.dismissResults,
                            updateInspectorContext:
                                updateResultInspectorContext
                        )
                    }
                }
                .frame(minHeight: 240, idealHeight: 320)
            }
        }
        .focusedSceneValue(
            \.workspaceQueryCommandActions,
            commandActions
        )
        .onChange(of: schemaCatalog, initial: true) { _, schemaCatalog in
            completionService.updateSchemaCatalog(schemaCatalog)
        }
        .onAppear {
            commandCoordinator.setExecutionPlanHandler(handleExecutionPlan)
        }
        .task {
            await document.refreshSchemas()
        }
        .onDisappear {
            commandCoordinator.setExecutionPlanHandler(nil)
        }
        .onChange(of: document.cancellationFailureMessage) { _, message in
            showsCancellationFailure = message != nil
        }
        .alert(
            settingsCopy.dangerousSQLAlertTitle,
            isPresented: $showsDangerousExecutionConfirmation,
            presenting: pendingDangerousExecution
        ) { execution in
            Button(settingsCopy.cancel, role: .cancel) {
                pendingDangerousExecution = nil
            }
            .keyboardShortcut(.cancelAction)
            Button(settingsCopy.executeDangerousSQL, role: .destructive) {
                pendingDangerousExecution = nil
                startExecution(execution)
            }
            .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text(settingsCopy.dangerousSQLAlertMessage)
        }
        .alert(
            AppCopy.current.text("无法停止查询", "Unable to Stop Query"),
            isPresented: $showsCancellationFailure
        ) {
            Button(
                AppCopy.current.text("断开会话", "Disconnect Session"),
                role: .destructive
            ) {
                Task {
                    await document.disconnectAfterCancellationFailure()
                }
            }
            .keyboardShortcut(.defaultAction)
            Button(
                AppCopy.current.text("保留会话", "Keep Session"),
                role: .cancel
            ) {}
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(document.cancellationFailureMessage ?? "")
        }
        .accessibilityIdentifier("queryDocumentView")
    }

    private var commandActions: WorkspaceQueryCommandActions {
        WorkspaceQueryCommandActions(
            selectionOrCurrentStatementAvailability: languageService
                .selectionOrCurrentStatementAvailability,
            runAllAvailability: languageService.runAllAvailability,
            isRunning: document.executionState.isRunning,
            transactionState: document.transactionState,
            requiresSessionDisconnect: document.cancellationFailureMessage != nil,
            canSave: document.canSave,
            save: commandCoordinator.save,
            runSelectionOrCurrentStatement: runSelectionOrCurrentStatement,
            runAll: runAll,
            stop: stop,
            commitTransaction: commitTransaction,
            rollbackTransaction: rollbackTransaction,
            formatSelectionOrCurrentStatement: formatSelectionOrCurrentStatement,
            formatDocument: formatDocument
        )
    }

    private func runSelectionOrCurrentStatement() {
        run(.selectionOrCurrentStatement)
    }

    private func runAll() {
        run(.all)
    }

    private func run(_ request: SQLExecutionTargetRequest) {
        Task {
            do {
                let plan = try await languageService.executionPlan(
                    for: request
                )
                handleExecutionPlan(plan)
            } catch {
                document.reportExecutionTargetFailure(error)
            }
        }
    }

    private func handleExecutionPlan(_ plan: SQLExecutionBatchPlan) {
        let policy: SQLExecutionPolicy
        do {
            policy = try safetyLock.executionPolicy(for: plan)
        } catch {
            document.reportExecutionTargetFailure(error)
            return
        }
        let execution = PendingDangerousQueryExecution(
            plan: plan,
            policy: policy,
            options: QueryExecutionOptions(
                statementTimeout: preferences.queryTimeout.duration,
                maximumResultRows: document.resultRowLimit.maximumRows
            )
        )
        if preferences.confirmsDangerousSQL,
           plan.requiresDangerousSQLConfirmation
        {
            pendingDangerousExecution = execution
            showsDangerousExecutionConfirmation = true
            return
        }
        startExecution(execution)
    }

    private func startExecution(
        _ execution: PendingDangerousQueryExecution
    ) {
        Task {
            await document.execute(
                execution.plan,
                policy: execution.policy,
                options: execution.options
            )
        }
    }

    private func stop() {
        Task {
            await document.stop()
        }
    }

    private func commitTransaction() {
        executeTransactionCommand(.commit)
    }

    private func rollbackTransaction() {
        executeTransactionCommand(.rollback)
    }

    private func disconnectSession() {
        Task {
            await document.disconnectAfterCancellationFailure()
        }
    }

    private func executeTransactionCommand(
        _ command: WorkspaceQueryTransactionCommand
    ) {
        Task {
            await document.executeTransactionCommand(command)
        }
    }

    private func formatSelectionOrCurrentStatement() {
        commandCoordinator.format(.selectionOrCurrentStatement)
    }

    private func formatDocument() {
        commandCoordinator.format(.document)
    }
}
