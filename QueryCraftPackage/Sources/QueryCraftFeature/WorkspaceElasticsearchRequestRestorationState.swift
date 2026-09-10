import Foundation

struct WorkspaceElasticsearchRequestRestorationState:
    Codable,
    Equatable,
    Sendable
{
    let id: UUID
    let title: String
    let source: String
    let resultRowLimit: QueryResultRowLimit
    let savedQueryID: SavedQuery.ID?
    let persistedSource: String?

    init(
        id: UUID,
        title: String,
        source: String,
        resultRowLimit: QueryResultRowLimit,
        savedQueryID: SavedQuery.ID? = nil,
        persistedSource: String? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.resultRowLimit = resultRowLimit
        self.savedQueryID = savedQueryID
        self.persistedSource = persistedSource
    }
}
