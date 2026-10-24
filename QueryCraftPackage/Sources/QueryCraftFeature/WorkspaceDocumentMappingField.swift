public struct WorkspaceDocumentMappingField: Equatable, Identifiable, Sendable {
    public let path: String
    public let type: String
    public let isIndexed: Bool
    public let isSearchable: Bool
    public let isAggregatable: Bool
    public let hasTypeConflict: Bool
    public let keywordSubfieldPath: String?

    public init(
        path: String,
        type: String,
        isIndexed: Bool,
        isSearchable: Bool,
        isAggregatable: Bool,
        hasTypeConflict: Bool = false,
        keywordSubfieldPath: String? = nil
    ) {
        self.path = path
        self.type = type
        self.isIndexed = isIndexed
        self.isSearchable = isSearchable
        self.isAggregatable = isAggregatable
        self.hasTypeConflict = hasTypeConflict
        self.keywordSubfieldPath = keywordSubfieldPath
    }

    public var id: String { path }
}
