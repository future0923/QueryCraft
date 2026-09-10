import QueryCraftFeature

extension RedisDriverWorkspaceSession {
    func executeRedisOptimisticMutation(
        _ request: RedisOptimisticMutationRequest
    ) async throws {
        try await requireClient().executeOptimisticMutation(request)
    }
}
