public struct WorkspaceDatabaseDataCellUpdate: Equatable, Sendable {
    public let selection: WorkspaceDatabaseObjectSelection
    public let columnName: String
    public let originalValue: WorkspaceDatabaseDataCell
    public let newValue: WorkspaceDatabaseDataCell
    public let primaryKey: [WorkspaceDatabaseDataCellUpdateCondition]
    public let assignment: WorkspaceDatabaseDataCellUpdateAssignment

    public init(
        selection: WorkspaceDatabaseObjectSelection,
        columnName: String,
        originalValue: WorkspaceDatabaseDataCell,
        newValue: WorkspaceDatabaseDataCell,
        primaryKey: [WorkspaceDatabaseDataCellUpdateCondition],
        assignment: WorkspaceDatabaseDataCellUpdateAssignment = .value
    ) {
        self.selection = selection
        self.columnName = columnName
        self.originalValue = originalValue
        self.newValue = newValue
        self.primaryKey = primaryKey
        self.assignment = assignment
    }
}
