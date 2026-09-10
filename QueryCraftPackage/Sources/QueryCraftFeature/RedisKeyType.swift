public enum RedisKeyType: String, Codable, CaseIterable, Sendable {
    case string
    case list
    case set
    case sortedSet = "zset"
    case hash
    case stream
    case module
    case none
    case unknown
}
