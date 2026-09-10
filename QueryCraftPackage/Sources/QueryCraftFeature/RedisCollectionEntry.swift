public enum RedisCollectionEntry: Equatable, Hashable, Sendable {
    case list(index: Int, value: RedisBinaryValue)
    case hash(
        field: RedisBinaryValue,
        value: RedisBinaryValue,
        ttlMilliseconds: Int64?
    )
    case set(member: RedisBinaryValue)
    case sortedSet(member: RedisBinaryValue, score: String)
}
