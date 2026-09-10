public struct WorkspaceDatabaseSchemaEditingDescriptor: Equatable, Sendable {
    public enum ColumnField: String, CaseIterable, Sendable {
        case name
        case type
        case characterSet
        case collation
        case primaryKey
        case nullable
        case defaultValue
        case automaticValue
        case generatedStorage
        case generationExpression
        case comment
    }

    public enum IndexField: String, CaseIterable, Sendable {
        case name
        case kind
        case columns
        case method
        case visible
        case comment
    }

    public enum AutomaticValueStyle: String, Sendable {
        case autoIncrement
        case identity
    }

    public let columnFields: [ColumnField]
    public let indexFields: [IndexField]
    public let defaultColumnType: String
    public let columnTypes: [String]
    public let indexKinds: [WorkspaceDatabaseSchemaEditorState.IndexKind]
    public let indexMethods: [String]
    public let generatedStorages: [
        WorkspaceDatabaseSchemaEditorState.GeneratedStorage
    ]
    public let automaticValueStyle: AutomaticValueStyle?
    public let supportsTableOptions: Bool
    public let supportsColumnVisibility: Bool
    public let supportsOnUpdateExpression: Bool
    public let supportsAlteringGeneratedColumns: Bool
    public let supportsIndexPrefixLength: Bool
    public let supportsIndexDirection: Bool

    public init(
        columnFields: [ColumnField],
        indexFields: [IndexField],
        defaultColumnType: String,
        columnTypes: [String],
        indexKinds: [WorkspaceDatabaseSchemaEditorState.IndexKind],
        indexMethods: [String],
        generatedStorages: [WorkspaceDatabaseSchemaEditorState.GeneratedStorage],
        automaticValueStyle: AutomaticValueStyle?,
        supportsTableOptions: Bool,
        supportsColumnVisibility: Bool,
        supportsOnUpdateExpression: Bool,
        supportsAlteringGeneratedColumns: Bool,
        supportsIndexPrefixLength: Bool,
        supportsIndexDirection: Bool
    ) {
        self.columnFields = columnFields
        self.indexFields = indexFields
        self.defaultColumnType = defaultColumnType
        self.columnTypes = columnTypes
        self.indexKinds = indexKinds
        self.indexMethods = indexMethods
        self.generatedStorages = generatedStorages
        self.automaticValueStyle = automaticValueStyle
        self.supportsTableOptions = supportsTableOptions
        self.supportsColumnVisibility = supportsColumnVisibility
        self.supportsOnUpdateExpression = supportsOnUpdateExpression
        self.supportsAlteringGeneratedColumns = supportsAlteringGeneratedColumns
        self.supportsIndexPrefixLength = supportsIndexPrefixLength
        self.supportsIndexDirection = supportsIndexDirection
    }

    public func includesColumn(_ field: ColumnField) -> Bool {
        columnFields.contains(field)
    }

    public func includesIndex(_ field: IndexField) -> Bool {
        indexFields.contains(field)
    }

    public var canEdit: Bool {
        !columnFields.isEmpty || !indexFields.isEmpty
    }

    public static let unavailable = Self(
        columnFields: [],
        indexFields: [],
        defaultColumnType: "",
        columnTypes: [],
        indexKinds: [],
        indexMethods: [],
        generatedStorages: [.none],
        automaticValueStyle: nil,
        supportsTableOptions: false,
        supportsColumnVisibility: false,
        supportsOnUpdateExpression: false,
        supportsAlteringGeneratedColumns: false,
        supportsIndexPrefixLength: false,
        supportsIndexDirection: false
    )
}
