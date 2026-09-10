enum WorkspacePendingChangesPreview: Equatable, Sendable {
    case sql([WorkspaceSQLPreviewStatement])
    case redis([RedisCommandInvocation])
    case elasticsearch([WorkspaceRequest])

    var isEmpty: Bool {
        switch self {
        case .sql(let statements):
            statements.isEmpty
        case .redis(let commands):
            commands.isEmpty
        case .elasticsearch(let requests):
            requests.isEmpty
        }
    }

    var isRedis: Bool {
        if case .redis = self { return true }
        return false
    }

    var isElasticsearch: Bool {
        if case .elasticsearch = self { return true }
        return false
    }
}
