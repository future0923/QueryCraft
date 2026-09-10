public struct WorkspaceDatabaseDataCellUpdateCondition: Equatable, Sendable {
    public let columnName: String
    public let value: WorkspaceDatabaseDataCell

    public init(columnName: String, value: WorkspaceDatabaseDataCell) {
        self.columnName = columnName
        self.value = value
    }
}
