public struct WorkspaceDatabaseObject: Equatable, Identifiable, Sendable {
    public let name: String
    public let kind: WorkspaceDatabaseObjectKind
    public let summary: WorkspaceDatabaseObjectSummary?

    public init(
        name: String,
        kind: WorkspaceDatabaseObjectKind,
        summary: WorkspaceDatabaseObjectSummary? = nil
    ) {
        self.name = name
        self.kind = kind
        self.summary = summary
    }

    public var id: String {
        "\(kind.rawValue):\(name)"
    }

    public var schemaName: String? {
        let parts = name.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        return parts.count == 2 ? String(parts[0]) : nil
    }

    public var nameWithinSchema: String {
        let parts = name.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        return parts.count == 2 ? String(parts[1]) : name
    }
}

public struct WorkspaceDatabaseObjectSummary: Equatable, Sendable {
    public let documentCount: Int?
    public let storageByteCount: Int64?
    public let health: String?

    public init(
        documentCount: Int? = nil,
        storageByteCount: Int64? = nil,
        health: String? = nil
    ) {
        self.documentCount = documentCount
        self.storageByteCount = storageByteCount
        self.health = health
    }
}
