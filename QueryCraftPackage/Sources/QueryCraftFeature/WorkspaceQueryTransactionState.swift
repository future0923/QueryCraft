public enum WorkspaceQueryTransactionState: Equatable, Sendable {
    case disconnected
    case autoCommit
    case inTransaction
}

public extension WorkspaceQueryTransactionState {
    func afterSuccessfulStatement(
        _ kind: SQLStatementKind
    ) throws -> WorkspaceQueryTransactionState {
        switch kind {
        case .transaction(.begin):
            return .inTransaction
        case .transaction(.commit), .transaction(.rollback):
            return .autoCommit
        case .transaction(.savepoint):
            return self
        case .read, .insert, .update, .delete:
            return self
        case .ddl where self == .autoCommit:
            return .autoCommit
        case .ddl, .transaction, .control, .unknown:
            throw WorkspaceSessionError.transactionStateUnavailable
        }
    }
}

enum WorkspaceQueryTransactionCommand: Equatable, Sendable {
    case begin
    case commit
    case rollback

    var sql: String {
        switch self {
        case .begin: "START TRANSACTION;"
        case .commit: "COMMIT;"
        case .rollback: "ROLLBACK;"
        }
    }

    var operation: SQLStatementKind.TransactionOperation {
        switch self {
        case .begin: .begin
        case .commit: .commit
        case .rollback: .rollback
        }
    }
}
