public protocol RedisCollectionPagingSession: RedisWorkspaceSession {
    func fetchRedisCollectionPage(
        _ query: RedisCollectionQuery
    ) async throws -> RedisCollectionPage
}
