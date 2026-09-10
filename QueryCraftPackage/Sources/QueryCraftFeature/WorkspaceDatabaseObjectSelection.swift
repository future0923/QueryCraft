public struct WorkspaceDatabaseObjectSelection:
    Codable,
    Equatable,
    Hashable,
    Identifiable,
    Sendable
{
    public let databaseName: String
    public let objectName: String
    public let kind: WorkspaceDatabaseObjectKind

    public init(
        databaseName: String,
        objectName: String,
        kind: WorkspaceDatabaseObjectKind
    ) {
        self.databaseName = databaseName
        self.objectName = objectName
        self.kind = kind
    }

    public var id: String {
        "\(databaseName):\(kind.rawValue):\(objectName)"
    }

    public var object: WorkspaceDatabaseObject {
        WorkspaceDatabaseObject(name: objectName, kind: kind)
    }
}
