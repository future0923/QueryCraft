public struct RedisKeyScanPage: Equatable, Sendable {
    public let nextCursor: UInt64
    public let keys: [RedisKeyReference]

    public init(nextCursor: UInt64, keys: [RedisKeyReference]) {
        self.nextCursor = nextCursor
        self.keys = keys
    }
}
