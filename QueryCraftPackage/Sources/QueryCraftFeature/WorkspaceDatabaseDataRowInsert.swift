public struct WorkspaceDatabaseDataRowInsert: Equatable, Sendable {
    public let selection: WorkspaceDatabaseObjectSelection
    public let values: [WorkspaceDatabaseDataRowInsertValue]

    public init(
        selection: WorkspaceDatabaseObjectSelection,
        values: [WorkspaceDatabaseDataRowInsertValue]
    ) {
        self.selection = selection
        self.values = values
    }
}

public struct WorkspaceDatabaseDataRowInsertValue: Equatable, Sendable {
    public let columnName: String
    public let value: WorkspaceDatabaseDataCell

    public init(columnName: String, value: WorkspaceDatabaseDataCell) {
        self.columnName = columnName
        self.value = value
    }
}
