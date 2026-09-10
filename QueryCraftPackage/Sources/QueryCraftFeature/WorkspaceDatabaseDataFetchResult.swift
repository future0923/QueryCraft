public struct WorkspaceDatabaseDataFetchResult: Sendable {
    public let columns: [WorkspaceDatabaseDataColumn]
    public let hasNextPage: Bool

    public init(columns: [WorkspaceDatabaseDataColumn], hasNextPage: Bool) {
        self.columns = columns
        self.hasNextPage = hasNextPage
    }
}
