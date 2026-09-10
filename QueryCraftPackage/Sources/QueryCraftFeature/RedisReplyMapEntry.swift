public struct RedisReplyMapEntry: Equatable, Sendable {
    public let key: RedisReplyValue
    public let value: RedisReplyValue

    public init(key: RedisReplyValue, value: RedisReplyValue) {
        self.key = key
        self.value = value
    }
}
