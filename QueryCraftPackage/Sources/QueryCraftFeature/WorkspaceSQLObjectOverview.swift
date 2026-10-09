/// Optional, additive API for bulk SQL metadata. Existing drivers can still
/// supply an object list without claiming to support these statistics.
public protocol WorkspaceSQLObjectOverviewProviding: Sendable {
    func fetchSQLObjectOverview(in database: String) async throws -> [WorkspaceSQLObjectOverviewEntry]
}

public struct WorkspaceSQLObjectOverviewEntry: Equatable, Sendable, Identifiable {
    public let object: WorkspaceDatabaseObject
    public let comment: String
    public let fieldCount: Int?
    public let estimatedRowCount: Int64?
    public let storageByteCount: Int64?
    public let engine: String?
    public let collation: String?

    public var id: String { object.id }

    public init(object: WorkspaceDatabaseObject, comment: String = "", fieldCount: Int? = nil,
                estimatedRowCount: Int64? = nil, storageByteCount: Int64? = nil,
                engine: String? = nil, collation: String? = nil) {
        self.object = object
        self.comment = comment
        self.fieldCount = fieldCount.flatMap { $0 >= 0 ? $0 : nil }
        self.estimatedRowCount = estimatedRowCount.flatMap { $0 >= 0 ? $0 : nil }
        self.storageByteCount = storageByteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.engine = engine.flatMap { $0.isEmpty ? nil : $0 }
        self.collation = collation.flatMap { $0.isEmpty ? nil : $0 }
    }
}
