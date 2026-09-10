struct WorkspaceDatabaseInspectorPendingUpdate: Equatable, Sendable {
    let update: WorkspaceDatabaseDataCellUpdate

    func matches(_ candidate: WorkspaceDatabaseDataCellUpdate) -> Bool {
        update.selection == candidate.selection
            && update.columnName == candidate.columnName
            && update.primaryKey == candidate.primaryKey
    }

    func applies(
        to row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn],
        dataColumnIndex: Int
    ) -> Bool {
        guard
            columns.indices.contains(dataColumnIndex),
            columns[dataColumnIndex].sourceColumnName == update.columnName
        else {
            return false
        }
        return update.primaryKey.allSatisfy { condition in
            guard let column = columns.first(where: {
                $0.sourceColumnName == condition.columnName
            }) else {
                return false
            }
            return row.value(at: column.id) == condition.value
        }
    }

    func applies(
        to row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn]
    ) -> Bool {
        update.primaryKey.allSatisfy { condition in
            guard let column = columns.first(where: {
                $0.sourceColumnName == condition.columnName
            }) else {
                return false
            }
            return row.value(at: column.id) == condition.value
        }
    }
}
