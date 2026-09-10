public struct RedisCollectionPage: Equatable, Sendable {
    public let entries: [RedisCollectionEntry]
    public let totalCount: Int
    public let scannedCount: Int
    public let matchingCount: Int?
    public let continuation: RedisCollectionContinuation?
    public let supportsHashFieldExpiration: Bool
    public let reachedRetainedLimit: Bool

    public init(
        entries: [RedisCollectionEntry],
        totalCount: Int,
        scannedCount: Int,
        matchingCount: Int?,
        continuation: RedisCollectionContinuation?,
        supportsHashFieldExpiration: Bool = false,
        reachedRetainedLimit: Bool = false
    ) {
        self.entries = entries
        self.totalCount = totalCount
        self.scannedCount = scannedCount
        self.matchingCount = matchingCount
        self.continuation = continuation
        self.supportsHashFieldExpiration = supportsHashFieldExpiration
        self.reachedRetainedLimit = reachedRetainedLimit
    }

    public var hasMore: Bool {
        continuation != nil && !reachedRetainedLimit
    }
}
