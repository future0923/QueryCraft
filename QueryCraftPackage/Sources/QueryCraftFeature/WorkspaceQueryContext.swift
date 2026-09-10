public struct WorkspaceQueryContext: Equatable, Sendable {
    public let databaseName: String?
    public let schemaName: String?

    public init(databaseName: String?, schemaName: String? = nil) {
        self.databaseName = databaseName
        self.schemaName = schemaName
    }
}
