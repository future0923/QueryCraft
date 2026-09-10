import Foundation

enum WorkspaceInspectorContext: Equatable {
    case database(WorkspaceDatabaseInspectorContext)
    case queryResult(WorkspaceQueryResultInspectorContext)
    case redisKey(WorkspaceRedisKeyInspectorContext)
    case elasticsearchDocument(WorkspaceElasticsearchDocumentInspectorContext)
    case elasticsearchMapping(WorkspaceMappingInspectorContext)
    case elasticsearchIndex(WorkspaceIndexInspectorContext)
    case schemaDraft(UUID, WorkspaceDatabaseSchemaInspectorContext)

    var searchIdentity: String {
        switch self {
        case .elasticsearchIndex(let context):
            "elasticsearch-index:\(context.selection.id)"
        case .elasticsearchMapping(let context):
            context.identity
        case .database(let context):
            "database:\(context.selection.id)"
        case .queryResult(let context):
            "query:\(context.resultID?.uuidString ?? "empty")"
        case .redisKey(let context):
            "redis-key:\(context.reference.id)"
        case .elasticsearchDocument(let context):
            "elasticsearch-document:\(context.reference?.index ?? "none"):\(context.reference?.id ?? "none")"
        case let .schemaDraft(draftID, context):
            "schema-draft:\(draftID.uuidString):\(context.item.identity)"
        }
    }
}

private extension WorkspaceDatabaseSchemaInspectorContext.Item {
    var identity: UUID {
        switch self {
        case let .column(item): item.id
        case let .index(item): item.id
        }
    }
}
