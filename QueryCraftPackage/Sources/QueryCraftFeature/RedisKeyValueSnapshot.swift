public struct RedisKeyValueSnapshot: Equatable, Sendable {
    public let columns: [String]
    public let rows: [[String]]
    public let isTruncated: Bool

    public init(
        columns: [String],
        rows: [[String]],
        isTruncated: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.isTruncated = isTruncated
    }
}
