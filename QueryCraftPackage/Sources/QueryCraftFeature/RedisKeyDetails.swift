public struct RedisKeyDetails: Equatable, Sendable {
    public let reference: RedisKeyReference
    public let ttlMilliseconds: Int64?
    public let memoryUsageBytes: Int64?
    public let encoding: String?
    public let value: RedisKeyValueSnapshot

    public init(
        reference: RedisKeyReference,
        ttlMilliseconds: Int64?,
        memoryUsageBytes: Int64?,
        encoding: String?,
        value: RedisKeyValueSnapshot
    ) {
        self.reference = reference
        self.ttlMilliseconds = ttlMilliseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.encoding = encoding
        self.value = value
    }
}
