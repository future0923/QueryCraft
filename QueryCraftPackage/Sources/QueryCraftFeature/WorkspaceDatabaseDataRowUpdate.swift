public struct WorkspaceDatabaseDataRowUpdate: Equatable, Sendable {
    public let selection: WorkspaceDatabaseObjectSelection
    public let primaryKey: [WorkspaceDatabaseDataCellUpdateCondition]
    public let assignments: [WorkspaceDatabaseDataCellUpdate]

    public init(
        selection: WorkspaceDatabaseObjectSelection,
        primaryKey: [WorkspaceDatabaseDataCellUpdateCondition],
        assignments: [WorkspaceDatabaseDataCellUpdate]
    ) {
        self.selection = selection
        self.primaryKey = primaryKey
        self.assignments = assignments
    }

    public static func group(
        _ updates: [WorkspaceDatabaseDataCellUpdate]
    ) -> [Self] {
        var rows: [Self] = []

        for update in updates {
            if let rowIndex = rows.firstIndex(where: {
                $0.selection == update.selection
                    && $0.primaryKey == update.primaryKey
            }) {
                var assignments = rows[rowIndex].assignments
                if let assignmentIndex = assignments.firstIndex(where: {
                    $0.columnName == update.columnName
                }) {
                    assignments[assignmentIndex] = update
                } else {
                    assignments.append(update)
                }
                rows[rowIndex] = Self(
                    selection: update.selection,
                    primaryKey: update.primaryKey,
                    assignments: assignments
                )
            } else {
                rows.append(Self(
                    selection: update.selection,
                    primaryKey: update.primaryKey,
                    assignments: [update]
                ))
            }
        }

        return rows
    }
}
