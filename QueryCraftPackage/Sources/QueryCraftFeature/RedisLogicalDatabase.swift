public struct RedisLogicalDatabase: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let keyCount: Int?

    public init(index: Int, keyCount: Int? = nil) {
        self.index = index
        self.keyCount = keyCount
    }

    public var id: Int { index }
    public var name: String { "DB \(index)" }
}
