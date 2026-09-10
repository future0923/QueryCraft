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
        let primaryKeyColumns = details.columns.filter {
            $0.key.uppercased() == "PRI"
        }
        guard !primaryKeyColumns.isEmpty else {
            throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
        }

        let conditions = try primaryKeyColumns.map { keyColumn in
            guard let pageColumn = page.columns.first(where: {
                $0.name == keyColumn.name
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
}
