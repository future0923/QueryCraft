public enum RedisCollectionSearchField: String, Equatable, Hashable, Sendable {
    case all
    case value
    case field
    case member
    case score
}

public enum RedisCollectionMatchMode: String, Equatable, Hashable, Sendable {
    case contains
    case prefix
    case exact
}

public struct RedisCollectionSearch: Equatable, Hashable, Sendable {
    public let text: String
    public let field: RedisCollectionSearchField
    public let mode: RedisCollectionMatchMode
    public let isCaseSensitive: Bool

    public init(
        text: String,
        field: RedisCollectionSearchField,
        mode: RedisCollectionMatchMode,
        isCaseSensitive: Bool
    ) {
        self.text = text
        self.field = field
        self.mode = mode
        self.isCaseSensitive = isCaseSensitive
    }
}
