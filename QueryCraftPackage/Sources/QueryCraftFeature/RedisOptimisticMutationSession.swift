public protocol RedisOptimisticMutationSession: RedisWorkspaceSession {
    func executeRedisOptimisticMutation(
        _ request: RedisOptimisticMutationRequest
    ) async throws
}
