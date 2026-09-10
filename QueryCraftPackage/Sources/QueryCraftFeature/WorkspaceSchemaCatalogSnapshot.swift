import Foundation

struct WorkspaceSchemaCatalogSnapshot: Equatable, Sendable {
    let revision: UInt64
    let databases: [WorkspaceSchemaDatabase]
    let loadedColumnObjects: Set<WorkspaceSchemaObjectReference>

    init(
        revision: UInt64,
        databases: [WorkspaceSchemaDatabase],
        loadedColumnObjects: Set<WorkspaceSchemaObjectReference> = []
    ) {
        self.revision = revision
        self.databases = databases
        self.loadedColumnObjects = loadedColumnObjects
    }

    static let empty = WorkspaceSchemaCatalogSnapshot(
        revision: 0,
        databases: []
    )

    func database(named name: String) -> WorkspaceSchemaDatabase? {
        databases.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func hasLoadedColumns(for reference: WorkspaceSchemaObjectReference) -> Bool {
        loadedColumnObjects.contains(reference)
    }
}

public struct WorkspaceSchemaObjectReference: Equatable, Hashable, Sendable {
    public let databaseName: String
    public let objectName: String

    public init(databaseName: String, objectName: String) {
        self.databaseName = databaseName
        self.objectName = objectName
    }

    public static func == (
        lhs: WorkspaceSchemaObjectReference,
        rhs: WorkspaceSchemaObjectReference
    ) -> Bool {
        lhs.databaseName.lowercased() == rhs.databaseName.lowercased()
            && lhs.objectName.lowercased() == rhs.objectName.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(databaseName.lowercased())
        hasher.combine(objectName.lowercased())
    }
}

public struct WorkspaceSchemaObjectColumns: Equatable, Sendable {
    public let reference: WorkspaceSchemaObjectReference
    public let columns: [WorkspaceSchemaColumn]

    public init(
        reference: WorkspaceSchemaObjectReference,
        columns: [WorkspaceSchemaColumn]
    ) {
        self.reference = reference
        self.columns = columns
    }
}

public struct WorkspaceSchemaDatabase: Equatable, Identifiable, Sendable {
    public let name: String
    public let objects: [WorkspaceSchemaObject]

    public init(name: String, objects: [WorkspaceSchemaObject]) {
        self.name = name
        self.objects = objects
    }

    public var id: String { name }

    public func object(named name: String) -> WorkspaceSchemaObject? {
        objects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct WorkspaceSchemaObject: Equatable, Identifiable, Sendable {
    public let name: String
    public let kind: WorkspaceDatabaseObjectKind
    public let columns: [WorkspaceSchemaColumn]

    public init(
        name: String,
        kind: WorkspaceDatabaseObjectKind,
        columns: [WorkspaceSchemaColumn]
    ) {
        self.name = name
        self.kind = kind
        self.columns = columns
    }

    public var id: String { "\(kind.rawValue):\(name)" }
}

public struct WorkspaceSchemaColumn: Equatable, Identifiable, Sendable {
    public let name: String
    public let type: String
    public let ordinalPosition: Int

    public init(name: String, type: String, ordinalPosition: Int) {
        self.name = name
        self.type = type
        self.ordinalPosition = ordinalPosition
    }

    public var id: String { name }
}
