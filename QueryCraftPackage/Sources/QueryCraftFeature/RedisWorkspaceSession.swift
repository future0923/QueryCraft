public protocol RedisWorkspaceSession: WorkspaceSession {
    func fetchRedisLogicalDatabases() async throws -> [RedisLogicalDatabase]

    func scanRedisKeys(
        databaseIndex: Int,
        cursor: UInt64,
        pattern: String?,
        count: Int
    ) async throws -> RedisKeyScanPage

    func fetchRedisKey(
        _ reference: RedisKeyReference,
        maximumElements: Int
    ) async throws -> RedisKeyDetails

    func executeRedisCommand(
        _ invocation: RedisCommandInvocation,
        databaseIndex: Int
    ) async throws -> RedisCommandResult
}
