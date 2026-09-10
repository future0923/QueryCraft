public struct WorkspaceDatabaseIndex: Equatable, Identifiable, Sendable {
    public let name: String
    public let columns: [WorkspaceDatabaseIndexColumn]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String
    public let cardinality: Int64?
    public let isVisible: Bool
    public let comment: String

    public init(
        name: String,
        columns: [WorkspaceDatabaseIndexColumn],
        isUnique: Bool,
        isPrimary: Bool = false,
        type: String,
        cardinality: Int64?,
        isVisible: Bool,
        comment: String
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.cardinality = cardinality
        self.isVisible = isVisible
        self.comment = comment
    }

    public var id: String { name }

    public var columnList: String {
        columns.map(\.displayName).joined(separator: ", ")
    }
}
