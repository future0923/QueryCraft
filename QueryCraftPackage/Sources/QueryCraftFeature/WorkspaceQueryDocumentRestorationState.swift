import Foundation

struct WorkspaceQueryDocumentRestorationState:
    Codable,
    Equatable,
    Sendable
{
    let id: UUID
    let title: String
    let savedQueryID: SavedQuery.ID?
    let defaultDatabase: String?
    let resultRowLimit: QueryResultRowLimit?

    init(
        id: UUID,
        title: String,
        savedQueryID: SavedQuery.ID?,
        defaultDatabase: String?,
        resultRowLimit: QueryResultRowLimit? = nil
    ) {
        self.id = id
        self.title = title
        self.savedQueryID = savedQueryID
        self.defaultDatabase = defaultDatabase
        self.resultRowLimit = resultRowLimit
    }
}


enum WorkspaceQuerySchemaSelection {
    static func resolved(current: String?, schemas: [String]) -> String? {
        if let current, schemas.contains(current) { return current }
        return schemas.contains("public") ? "public" : schemas.first
    }
}
