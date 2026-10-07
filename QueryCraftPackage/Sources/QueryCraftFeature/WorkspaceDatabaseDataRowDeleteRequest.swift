struct WorkspaceDatabaseDataRowDeleteRequest: Equatable, Sendable {
    static func make(
        selection: WorkspaceDatabaseObjectSelection,
        rowIndex: Int,
        page: WorkspaceDatabaseDataPage,
        details: WorkspaceDatabaseObjectDetails
    ) throws -> WorkspaceDatabaseDataRowDelete {
        guard selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        guard let row = page.row(at: rowIndex) else {
            throw WorkspaceDatabaseDataRowDeleteError.rowUnavailable
        }
        return try make(
            selection: selection,
            row: row,
            columns: page.columns,
            details: details
        )
    }

    /// Builds a delete request from a row whose columns may come from a query
    /// result. Query result columns can be aliases, so primary-key columns are
    /// matched by their source origin when one is available.
    static func make(
        selection: WorkspaceDatabaseObjectSelection,
        row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn],
        details: WorkspaceDatabaseObjectDetails
    ) throws -> WorkspaceDatabaseDataRowDelete {
        guard selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        let primaryKeyColumns = details.columns.filter {
            $0.key.uppercased() == "PRI"
        }
        guard !primaryKeyColumns.isEmpty else {
            throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
        }

        let conditions = try primaryKeyColumns.map { keyColumn in
            guard let pageColumn = columns.first(where: {
                $0.origin?.columnName == keyColumn.name
                    || ($0.origin == nil && $0.name == keyColumn.name)
            }) else {
                throw WorkspaceDatabaseDataRowDeleteError
                    .primaryKeyValueUnavailable(keyColumn.name)
            }
            if case .binary = row.value(at: pageColumn.id) {
                throw WorkspaceDatabaseDataRowDeleteError
                    .primaryKeyValueUnavailable(keyColumn.name)
            }
            return WorkspaceDatabaseDataCellUpdateCondition(
                columnName: keyColumn.name,
                value: row.value(at: pageColumn.id)
            )
        }
        return WorkspaceDatabaseDataRowDelete(
            selection: selection,
            conditions: conditions
        )
    }

    static func make(
        selection: WorkspaceDatabaseObjectSelection,
        rowIndex: Int,
        page: WorkspaceQueryResultPage,
        details: WorkspaceDatabaseObjectDetails
    ) throws -> WorkspaceDatabaseDataRowDelete {
        guard selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        guard let row = page.row(at: rowIndex) else {
            throw WorkspaceDatabaseDataRowDeleteError.rowUnavailable
        }
        return try make(
            selection: selection,
            row: row,
            columns: page.columns,
            details: details
        )
    }
}
