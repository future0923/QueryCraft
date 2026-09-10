public enum SQLStatementKind: Equatable, Sendable {
    public enum DDLOperation: Equatable, Sendable {
        case create
        case alter
        case drop
        case truncate
        case other
    }

    public enum TransactionOperation: Equatable, Sendable {
        case begin
        case commit
        case rollback
        case savepoint
        case other
    }

    case read
    case insert
    case update(hasWhereClause: Bool)
    case delete(hasWhereClause: Bool)
    case ddl(DDLOperation)
    case transaction(TransactionOperation)
    case control
    case unknown

    public var requiresWriteAccess: Bool {
        switch self {
        case .read, .transaction:
            false
        case .insert, .update, .delete, .ddl, .control, .unknown:
            true
        }
    }

    public var requiresDangerousSQLConfirmation: Bool {
        switch self {
        case .update, .delete, .ddl(.drop), .ddl(.truncate):
            true
        case .read, .insert, .ddl, .transaction, .control, .unknown:
            false
        }
    }
}
