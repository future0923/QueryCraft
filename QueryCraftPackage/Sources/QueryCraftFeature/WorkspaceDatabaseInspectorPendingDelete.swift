struct WorkspaceDatabaseInspectorPendingDelete: Equatable, Sendable {
    let rowDelete: WorkspaceDatabaseDataRowDelete
    let replacedUpdates: [WorkspaceDatabaseInspectorPendingUpdate]

    init(
        rowDelete: WorkspaceDatabaseDataRowDelete,
        replacedUpdates: [WorkspaceDatabaseInspectorPendingUpdate] = []
    ) {
        self.rowDelete = rowDelete
        self.replacedUpdates = replacedUpdates
    }

    func matches(_ candidate: WorkspaceDatabaseDataRowDelete) -> Bool {
        rowDelete.selection == candidate.selection
            && rowDelete.conditions == candidate.conditions
    }

    func applies(
        to row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn]
    ) -> Bool {
        rowDelete.conditions.allSatisfy { condition in
            guard let column = columns.first(where: {
                $0.name == condition.columnName
            }) else {
                return false
            }
            return row.value(at: column.id) == condition.value
        }
    }
}
