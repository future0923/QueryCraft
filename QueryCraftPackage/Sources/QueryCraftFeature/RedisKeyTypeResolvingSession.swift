public protocol RedisKeyTypeResolvingSession: RedisWorkspaceSession {
    func resolveRedisKeyTypes(
        _ references: [RedisKeyReference]
    ) async throws -> [RedisKeyReference]
}
