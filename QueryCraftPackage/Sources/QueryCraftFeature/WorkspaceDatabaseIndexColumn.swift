public struct WorkspaceDatabaseIndexColumn: Equatable, Identifiable, Sendable {
    public let sequence: Int64
    public let name: String
    public let prefixLength: Int64?
    public let direction: String?
    public let isExpression: Bool

    public init(
        sequence: Int64,
        name: String,
        prefixLength: Int64?,
        direction: String?,
        isExpression: Bool
    ) {
        self.sequence = sequence
        self.name = name
        self.prefixLength = prefixLength
        self.direction = direction
        self.isExpression = isExpression
    }

    public var id: Int64 { sequence }

    public var displayName: String {
        var value = isExpression ? "(\(name))" : name
        if let prefixLength {
            value += "(\(prefixLength))"
        }
        if direction == "D" {
            value += " DESC"
        }
        return value
    }
}
