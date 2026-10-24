import Foundation
public struct WorkspaceDatabaseObject: Equatable, Identifiable, Sendable {
    public let name: String
    public let kind: WorkspaceDatabaseObjectKind
    public let summary: WorkspaceDatabaseObjectSummary?

    public init(
        name: String,
        kind: WorkspaceDatabaseObjectKind,
        summary: WorkspaceDatabaseObjectSummary? = nil
    ) {
        self.name = name
        self.kind = kind
        self.summary = summary
    }

    public var id: String {
        "\(kind.rawValue):\(name)"
    }

    /// Preserve legacy display names and decode explicit SQL-quoted identities.
    /// Dots and escaped quotes inside either physical identifier stay literal.
    public static func postgreSQLName(schema: String, table: String) -> String {
        if schema.contains(".") || schema.contains("\"") {
            return [schema, table].map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ".")
        }
        return schema + "." + table
    }
    private var nameParts: [String] {
        if name.first == "\"" {
            let chars = Array(name); var index = 0; var parts: [String] = []
            while index < chars.count {
                guard chars[index] == "\"" else { break }
                index += 1; var part = ""; var closed = false
                while index < chars.count {
                    let character = chars[index]; index += 1
                    if character == "\"" {
                        if index < chars.count, chars[index] == "\"" { part.append("\""); index += 1 }
                        else { closed = true; break }
                    } else { part.append(character) }
                }
                guard closed else { break }; parts.append(part)
                if index == chars.count, parts.count == 2 { return parts }
                guard index < chars.count, chars[index] == "." else { break }; index += 1
            }
        }
        return name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    }
    public var schemaName: String? { let parts = nameParts; return parts.count == 2 ? parts[0] : nil }
    public var nameWithinSchema: String { let parts = nameParts; return parts.count == 2 ? parts[1] : name }

}

public struct WorkspaceDatabaseObjectSummary: Equatable, Sendable {
    public let documentCount: Int?
    public let storageByteCount: Int64?
    public let health: String?

    public init(
        documentCount: Int? = nil,
        storageByteCount: Int64? = nil,
        health: String? = nil
    ) {
        self.documentCount = documentCount
        self.storageByteCount = storageByteCount
        self.health = health
    }
}
