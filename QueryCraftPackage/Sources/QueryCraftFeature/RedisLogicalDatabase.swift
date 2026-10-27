import Foundation

public struct RedisLogicalDatabase: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let index: Int
    public let keyCount: Int?

    public init(index: Int, keyCount: Int? = nil) {
        self.index = index
        self.keyCount = keyCount
    }

    public var id: Int { index }
    public var name: String { "DB \(index)" }

    /// Accept the saved/display name and the numeric MCP selector as one logical DB.
    public static func index(from name: String?) -> Int? {
        guard let name, !name.isEmpty else { return 0 }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = trimmed.lowercased().hasPrefix("db ") ? String(trimmed.dropFirst(3)) : trimmed
        guard let index = Int(number), index >= 0 else { return nil }
        return index
    }
}
