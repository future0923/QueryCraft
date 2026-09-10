public struct WorkspaceDatabaseDataBatch: Sendable {
    public let columns: [WorkspaceDatabaseDataColumn]
    public let rows: [WorkspaceDatabaseDataRow]

    public init(
        columns: [WorkspaceDatabaseDataColumn],
        rows: [WorkspaceDatabaseDataRow]
    ) {
        self.columns = columns
        self.rows = rows
    }
}
