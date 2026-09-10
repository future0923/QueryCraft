import Foundation

enum WorkspaceContentTabItem: Identifiable {
    case query(WorkspaceQueryTabItem)
    case databaseObject(WorkspaceDatabaseObjectSelection)
    case newTable(WorkspaceNewTableDraft)
    case redisKey(RedisKeyReference)
    case redisCommand(WorkspaceRedisCommandDocumentModel)
    case elasticsearchRequest(WorkspaceElasticsearchRequestDocumentModel)

    var id: WorkspaceContentTabID {
        switch self {
        case let .query(item):
            .queryDocument(item.id)
        case let .databaseObject(selection):
            .databaseObject(selection)
        case let .newTable(draft):
            .newTable(draft.id)
        case let .redisKey(reference):
            .redisKey(reference)
        case let .redisCommand(document):
            .redisCommand(document.id)
        case let .elasticsearchRequest(document):
            .elasticsearchRequest(document.id)
        }
    }

    @MainActor
    var title: String {
        switch self {
        case let .query(item):
            item.document.title
        case let .databaseObject(selection):
            selection.objectName
        case let .newTable(draft):
            draft.title
        case let .redisKey(reference):
            reference.name
        case let .redisCommand(document):
            document.title
        case let .elasticsearchRequest(document):
            document.title
        }
    }

    @MainActor
    var databaseName: String? {
        switch self {
        case let .query(item):
            item.document.databaseName
        case let .databaseObject(selection):
            selection.databaseName
        case let .newTable(draft):
            draft.databaseName
        case let .redisKey(reference):
            "DB \(reference.databaseIndex)"
        case .redisCommand, .elasticsearchRequest:
            nil
        }
    }
}
