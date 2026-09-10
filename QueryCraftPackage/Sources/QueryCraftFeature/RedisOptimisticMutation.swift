public enum RedisMutationAssertion: Equatable, Sendable {
    case keyType(RedisKeyType)
    case elementCount(Int)
    case stringValue(RedisBinaryValue)
    case listElement(index: Int, value: RedisBinaryValue)
    case hashValue(field: RedisBinaryValue, value: RedisBinaryValue?)
    case setMembership(member: RedisBinaryValue, exists: Bool)
    case sortedSetScore(member: RedisBinaryValue, score: String?)
}

public enum RedisMutationOperation: Equatable, Sendable {
    case command(RedisBinaryCommandInvocation)
    case deleteListElement(index: Int, originalValue: RedisBinaryValue)
}

public struct RedisOptimisticMutationRequest: Equatable, Sendable {
    public let reference: RedisKeyReference
    public let assertions: [RedisMutationAssertion]
    public let operations: [RedisMutationOperation]

    public init(
        reference: RedisKeyReference,
        assertions: [RedisMutationAssertion],
        operations: [RedisMutationOperation]
    ) {
        self.reference = reference
        self.assertions = assertions
        self.operations = operations
    }
}

public protocol RedisOptimisticMutationSession: RedisWorkspaceSession {
    func executeRedisOptimisticMutation(
        _ request: RedisOptimisticMutationRequest
    ) async throws
}
