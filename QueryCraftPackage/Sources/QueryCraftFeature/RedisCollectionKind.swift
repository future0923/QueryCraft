public enum RedisCollectionKind: String, Equatable, Hashable, Sendable {
    case list
    case hash
    case set
    case sortedSet
}
