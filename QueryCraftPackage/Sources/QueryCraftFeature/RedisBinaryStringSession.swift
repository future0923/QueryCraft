public protocol RedisBinaryStringSession: RedisWorkspaceSession {
    func fetchRedisStringChunk(
        _ reference: RedisKeyReference,
        offset: Int,
        maximumBytes: Int
    ) async throws -> RedisStringChunk
}
