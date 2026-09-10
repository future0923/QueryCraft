public struct RedisCollectionQuery: Equatable, Sendable {
    public let reference: RedisKeyReference
    public let continuation: RedisCollectionContinuation?
    public let limit: Int
    public let search: RedisCollectionSearch?
    public let sortOrder: RedisCollectionSortOrder

    public init(
        reference: RedisKeyReference,
        continuation: RedisCollectionContinuation? = nil,
        limit: Int = 500,
        search: RedisCollectionSearch? = nil,
        sortOrder: RedisCollectionSortOrder = .descending
    ) {
        self.reference = reference
        self.continuation = continuation
        self.limit = limit
        self.search = search
        self.sortOrder = sortOrder
    }
}
