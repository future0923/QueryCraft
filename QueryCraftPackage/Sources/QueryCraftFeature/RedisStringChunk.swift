public struct RedisStringChunk: Equatable, Sendable {
    public let value: RedisBinaryValue
    public let offset: Int
    public let totalByteCount: Int

    public init(
        value: RedisBinaryValue,
        offset: Int,
        totalByteCount: Int
    ) {
        self.value = value
        self.offset = offset
        self.totalByteCount = totalByteCount
    }

    public var nextOffset: Int {
        offset + value.data.count
    }

    public var hasMore: Bool {
        nextOffset < totalByteCount
    }
}
