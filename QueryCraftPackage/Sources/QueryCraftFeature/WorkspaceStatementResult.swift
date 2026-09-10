struct WorkspaceStatementResult: Equatable, Sendable, Identifiable {
    let statement: SQLExecutionStatement
    var state: WorkspaceQueryExecutionState
    var elapsedSeconds: Double

    var id: Int { statement.index }
}
