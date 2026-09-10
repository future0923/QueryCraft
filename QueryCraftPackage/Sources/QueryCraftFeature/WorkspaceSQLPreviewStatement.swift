struct WorkspaceSQLPreviewStatement: Equatable, Sendable {
    let tokens: [WorkspaceSQLPreviewToken]

    var sql: String {
        tokens.map(\.text).joined()
    }

    static func make(
        schemaExecutionPlan: WorkspaceDatabaseSchemaExecutionPlan
    ) -> [Self] {
        schemaExecutionPlan.statements.map { Self(tokens: $0.previewTokens) }
    }

    static func make(
        rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState,
        databaseType: DatabaseType = .mysql
    ) throws -> Self {
        let insert = try rowInsertEditor.makeInsert()
        return try make(rowInsert: insert, databaseType: databaseType)
    }

    static func make(
        rowInsert: WorkspaceDatabaseDataRowInsert,
        databaseType: DatabaseType = .mysql
    ) throws -> Self {
        if databaseType == .postgresql {
            return try PostgreSQLWorkspaceDataPreviewStatement.make(
                rowInsert: rowInsert
            )
        }
        let statement = try MySQLWorkspaceDataRowInsertStatement.make(
            insert: rowInsert
        )
        return Self(tokens: statement.previewTokens)
    }

    static func make(
        rowDelete: WorkspaceDatabaseDataRowDelete,
        databaseType: DatabaseType = .mysql
    ) throws -> Self {
        if databaseType == .postgresql {
            return try PostgreSQLWorkspaceDataPreviewStatement.make(
                rowDelete: rowDelete
            )
        }
        let statement = try MySQLWorkspaceDataRowDeleteStatement.make(
            delete: rowDelete
        )
        return Self(tokens: statement.previewTokens)
    }

    static func make(
        cellUpdate: WorkspaceDatabaseDataCellUpdate,
        databaseType: DatabaseType = .mysql
    ) throws -> Self {
        if databaseType == .postgresql {
            return try PostgreSQLWorkspaceDataPreviewStatement.make(
                rowUpdate: WorkspaceDatabaseDataRowUpdate(
                    selection: cellUpdate.selection,
                    primaryKey: cellUpdate.primaryKey,
                    assignments: [cellUpdate]
                )
            )
        }
        let statement = try MySQLWorkspaceDataCellUpdateStatement.make(
            update: cellUpdate
        )
        return Self(tokens: statement.previewTokens)
    }

    static func make(
        rowUpdate: WorkspaceDatabaseDataRowUpdate,
        databaseType: DatabaseType = .mysql
    ) throws -> Self {
        if databaseType == .postgresql {
            return try PostgreSQLWorkspaceDataPreviewStatement.make(
                rowUpdate: rowUpdate
            )
        }
        let statement = try MySQLWorkspaceDataCellUpdateStatement.make(
            rowUpdate: rowUpdate
        )
        return Self(tokens: statement.previewTokens)
    }

}
