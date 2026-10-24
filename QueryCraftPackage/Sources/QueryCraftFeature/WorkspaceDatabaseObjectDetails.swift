public struct WorkspaceDatabaseObjectDetails: Equatable, Sendable {
    public let columns: [WorkspaceDatabaseColumn]
    public let ddl: String
    public let tableInformation: WorkspaceDatabaseTableInformation?
    public let schemaChoices: WorkspaceDatabaseSchemaChoices
    public let documentMappingFields: [WorkspaceDocumentMappingField]?

    public init(
        columns: [WorkspaceDatabaseColumn],
        ddl: String,
        tableInformation: WorkspaceDatabaseTableInformation? = nil,
        schemaChoices: WorkspaceDatabaseSchemaChoices = .empty,
        documentMappingFields: [WorkspaceDocumentMappingField]? = nil
    ) {
        self.columns = columns
        self.ddl = ddl
        self.tableInformation = tableInformation
        self.schemaChoices = schemaChoices
        self.documentMappingFields = documentMappingFields
    }
}
