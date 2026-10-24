#if os(iOS)
import QueryCraftMobileCore
#endif

struct RedisKeyMetadataMutationPlan: Equatable, Sendable {
    let reference: RedisKeyReference
    let command: RedisCommandInvocation
    static func delete(_ reference: RedisKeyReference) -> Self {
        .init(reference: reference, command: invocation(["DEL", reference.name]))
    }
    static func expiration(_ reference: RedisKeyReference, mode: RedisKeyExpirationMode, milliseconds: String) throws -> Self {
        if mode == .persistent { return .init(reference: reference, command: invocation(["PERSIST", reference.name])) }
        guard let ttl = Int64(milliseconds), ttl > 0 else { throw RedisKeyEditError.invalidTTL }
        return .init(reference: reference, command: invocation(["PEXPIRE", reference.name, String(ttl)]))
    }
    var optimisticRequest: RedisOptimisticMutationRequest {
        .init(reference: reference, assertions: reference.type == .unknown ? [] : [.keyType(reference.type)], operations: [.command(.init(source: command.source, utf8Arguments: command.arguments))])
    }
    private static func invocation(_ arguments: [String]) -> RedisCommandInvocation {
        .init(source: RedisCommandPreviewFormatter.source(for: .init(source: "", arguments: arguments)), arguments: arguments)
    }
}
