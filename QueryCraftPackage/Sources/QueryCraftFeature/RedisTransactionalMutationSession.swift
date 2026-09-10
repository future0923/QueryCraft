public protocol RedisTransactionalMutationSession: RedisWorkspaceSession {
    func executeRedisTransaction(
        _ invocations: [RedisCommandInvocation],
        databaseIndex: Int
    ) async throws
}
