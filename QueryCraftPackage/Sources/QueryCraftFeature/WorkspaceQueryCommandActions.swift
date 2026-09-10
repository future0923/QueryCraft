import Foundation

struct WorkspaceQueryCommandActions {
    let selectionOrCurrentStatementAvailability: SQLExecutionTargetAvailability
    let runAllAvailability: SQLExecutionTargetAvailability
    let isRunning: Bool
    let transactionState: WorkspaceQueryTransactionState
    let requiresSessionDisconnect: Bool
    let canSave: Bool
    let save: @MainActor @Sendable () -> Void
    let runSelectionOrCurrentStatement: @MainActor @Sendable () -> Void
    let runAll: @MainActor @Sendable () -> Void
    let stop: @MainActor @Sendable () -> Void
    let commitTransaction: @MainActor @Sendable () -> Void
    let rollbackTransaction: @MainActor @Sendable () -> Void
    let formatSelectionOrCurrentStatement: @MainActor @Sendable () -> Void
    let formatDocument: @MainActor @Sendable () -> Void
}
