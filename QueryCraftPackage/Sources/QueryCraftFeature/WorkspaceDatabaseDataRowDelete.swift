public struct WorkspaceDatabaseDataRowDelete: Equatable, Sendable {
    public let selection: WorkspaceDatabaseObjectSelection
    public let conditions: [WorkspaceDatabaseDataCellUpdateCondition]

    public init(
        selection: WorkspaceDatabaseObjectSelection,
        conditions: [WorkspaceDatabaseDataCellUpdateCondition]
    ) {
        self.selection = selection
        self.conditions = conditions
    }
}
