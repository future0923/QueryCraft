import QueryCraftFeature

struct MySQLSchemaEditingProvider: DatabaseSchemaEditingProvider {
    static let dialectIdentifier = "mysql"

    let descriptor = WorkspaceDatabaseSchemaEditingDescriptor(
        columnFields: WorkspaceDatabaseSchemaEditingDescriptor.ColumnField
            .allCases,
        indexFields: WorkspaceDatabaseSchemaEditingDescriptor.IndexField
            .allCases,
        defaultColumnType: "VARCHAR(255)",
        columnTypes: WorkspaceDatabaseSchemaChoiceCatalog.columnTypeValues,
        indexKinds: WorkspaceDatabaseSchemaEditorState.IndexKind.allCases,
        indexMethods: ["BTREE", "HASH"],
        generatedStorages: WorkspaceDatabaseSchemaEditorState.GeneratedStorage
            .allCases,
        automaticValueStyle: .autoIncrement,
        supportsTableOptions: true,
        supportsColumnVisibility: true,
        supportsOnUpdateExpression: true,
        supportsAlteringGeneratedColumns: true,
        supportsIndexPrefixLength: true,
        supportsIndexDirection: true
    )

    func makeExecutionPlan(
        for changes: WorkspaceDatabaseSchemaChangeSet
    ) -> WorkspaceDatabaseSchemaExecutionPlan {
        WorkspaceDatabaseSchemaExecutionPlan(
            dialectIdentifier: Self.dialectIdentifier,
            source: .changes(changes),
            transactionMode: .none,
            statements: MySQLWorkspaceSchemaStatement.make(changes: changes)
                .map {
                    .init(
                        sql: $0.sql,
                        previewTokens: $0.previewTokens,
                        kind: .ddl(.alter)
                    )
                }
        )
    }

    func makeExecutionPlan(
        for mutation: WorkspaceDatabaseTableMutation
    ) -> WorkspaceDatabaseSchemaExecutionPlan {
        let statement = MySQLWorkspaceSchemaStatement.make(
            tableMutation: mutation
        )
        return WorkspaceDatabaseSchemaExecutionPlan(
            dialectIdentifier: Self.dialectIdentifier,
            source: .tableMutation(mutation),
            transactionMode: .none,
            statements: [
                .init(
                    sql: statement.sql,
                    previewTokens: statement.previewTokens,
                    kind: mutation.statementKind
                ),
            ]
        )
    }
}
