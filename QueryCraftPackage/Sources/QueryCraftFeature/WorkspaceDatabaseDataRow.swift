public struct WorkspaceDatabaseDataRow: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let values: [WorkspaceDatabaseDataCell]

    public init(id: Int, values: [WorkspaceDatabaseDataCell]) {
        self.id = id
        self.values = values
    }

    public func value(at columnIndex: Int) -> WorkspaceDatabaseDataCell {
        guard values.indices.contains(columnIndex) else { return .null }
        return values[columnIndex]
    }
}
