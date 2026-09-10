public struct RedisKeyReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let databaseIndex: Int
    public let name: String
    public let type: RedisKeyType

    public init(
        databaseIndex: Int,
        name: String,
        type: RedisKeyType = .unknown
    ) {
        self.databaseIndex = databaseIndex
        self.name = name
        self.type = type
    }

    public var id: String { "\(databaseIndex):\(name)" }

    public static func == (
        lhs: RedisKeyReference,
        rhs: RedisKeyReference
    ) -> Bool {
        lhs.databaseIndex == rhs.databaseIndex && lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(databaseIndex)
        hasher.combine(name)
    }
}
