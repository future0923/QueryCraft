struct RedisKeyScanResult: Equatable, Sendable {
    let keys: [RedisKeyReference]
    let nextCursor: UInt64
}
