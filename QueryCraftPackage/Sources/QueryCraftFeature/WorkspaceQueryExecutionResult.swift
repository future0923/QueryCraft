public struct WorkspaceQueryExecutionResult: Equatable, Sendable {
    public let columns: [WorkspaceDatabaseDataColumn]
    public let rowCount: Int
    public let transactionState: WorkspaceQueryTransactionState

    public init(
        columns: [WorkspaceDatabaseDataColumn],
        rowCount: Int,
        transactionState: WorkspaceQueryTransactionState = .autoCommit
    ) {
        self.columns = columns
        self.rowCount = rowCount
        self.transactionState = transactionState
    }
}
