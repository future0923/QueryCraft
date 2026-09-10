public struct WorkspaceDatabaseDataColumn: Equatable, Identifiable, Sendable {
    public struct Origin: Equatable, Sendable {
        public let databaseName: String?
        public let schemaName: String?
        public let tableName: String
        public let columnName: String

        public init(
            databaseName: String? = nil,
            schemaName: String? = nil,
            tableName: String,
            columnName: String
        ) {
            self.databaseName = databaseName
            self.schemaName = schemaName
            self.tableName = tableName
            self.columnName = columnName
        }
    }

    public let id: Int
    public let name: String
    public let type: String?
    public let origin: Origin?

    public init(id: Int, name: String, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        origin = nil
    }

    public init(
        id: Int,
        name: String,
        type: String? = nil,
        origin: Origin?
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.origin = origin
    }

    var sourceColumnName: String { origin?.columnName ?? name }
}
