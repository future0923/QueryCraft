public struct WorkspaceDatabaseSchemaExecutionPlan: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case changes(WorkspaceDatabaseSchemaChangeSet)
        case tableMutation(WorkspaceDatabaseTableMutation)
    }

    public enum TransactionMode: Equatable, Sendable {
        case none
        case transaction
    }

    public struct Statement: Equatable, Sendable {
        public let sql: String
        public let previewTokens: [WorkspaceSQLPreviewToken]
        public let kind: SQLStatementKind

        public init(
            sql: String,
            previewTokens: [WorkspaceSQLPreviewToken],
            kind: SQLStatementKind
        ) {
            self.sql = sql
            self.previewTokens = previewTokens
            self.kind = kind
        }
    }

    public let dialectIdentifier: String
    public let source: Source
    public let transactionMode: TransactionMode
    public let statements: [Statement]

    public init(
        dialectIdentifier: String,
        source: Source,
        transactionMode: TransactionMode,
        statements: [Statement]
    ) {
        self.dialectIdentifier = dialectIdentifier
        self.source = source
        self.transactionMode = transactionMode
        self.statements = statements
    }
}
