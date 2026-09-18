import Foundation

enum WorkspaceContentTabID: Codable, Equatable, Hashable, Sendable {
    case queryDocument(UUID)
    case databaseObject(WorkspaceDatabaseObjectSelection)
    case newTable(UUID)
    case redisKey(RedisKeyReference)
    case redisNewKey(UUID)
    case redisCommand(UUID)
    case elasticsearchRequest(UUID)
}
