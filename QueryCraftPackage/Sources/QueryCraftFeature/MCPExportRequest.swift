import Foundation
import CryptoKit

/// Export budgets are independent of chat row/cell budgets. Callers may lower them only.
struct MCPExportLimits: Codable, Equatable, Sendable {
    var rows = 1_000_000
    var fileBytes = 512 * 1_024 * 1_024
    var rawBytes = 2 * 1_024 * 1_024 * 1_024
    var timeoutSeconds = 600
    static let rowBytes = 8 * 1_024 * 1_024
}

struct MCPExportColumn: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, integer, decimal, date, datetime }
    let sourceIndex: Int
    let title: String
    let kind: Kind
    let dateFormat: String?
    let width: Int?
}

struct MCPExportQuery: Codable, Equatable, Sendable {
    let name: String
    let sql: String
    let columns: [MCPExportColumn]?
    let expectedRows: Int?
}

struct MCPExportRequest: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case xlsx, csv }
    enum Consistency: String, Codable, Sendable { case singleSnapshot = "single_snapshot", perQuery = "per_query" }
    let connectionID: UUID
    let database: String
    let format: Format
    let queries: [MCPExportQuery]
    let consistency: Consistency
    /// MySQL numeric offset avoids relying on populated server timezone tables.
    let timezone: String
    let filename: String
    let limits: MCPExportLimits
    let idempotencyKey: String

    var fileExtension: String { format == .xlsx ? "xlsx" : queries.count > 1 ? "zip" : "csv" }

    init(arguments a: [String: MCPJSONValue]) throws {
        guard let id = UUID(uuidString: try a.requiredString("connection_id")) else { throw Self.invalid("connection_id must be a UUID.") }
        connectionID = id
        database = try a.requiredString("database")
        guard !database.isEmpty, database.utf8.count <= 256, !database.contains("\0") else { throw Self.invalid("Invalid database.") }
        guard let format = Format(rawValue: try a.requiredString("format")) else { throw Self.invalid("Use xlsx or csv.") }
        self.format = format
        guard let consistency = Consistency(rawValue: a.string("consistency") ?? "single_snapshot") else { throw Self.invalid("Invalid consistency.") }
        self.consistency = consistency
        timezone = a.string("timezone") ?? "+00:00"
        guard timezone.range(of: #"^[+-](?:0[0-9]|1[0-3]):[0-5][0-9]$|^\+14:00$"#, options: .regularExpression) != nil else {
            throw Self.invalid("timezone must be an explicit MySQL UTC offset, e.g. +08:00. DATETIME values are not timezone-converted.")
        }
        idempotencyKey = try a.requiredString("idempotency_key")
        guard UUID(uuidString: idempotencyKey) != nil else { throw Self.invalid("Use a fresh UUID idempotency_key; retain it for submission recovery.") }
        var limits = MCPExportLimits()
        if let values = a["limits"]?.objectValue {
            try Self.keys(values, allowed: ["max_rows", "max_file_bytes", "max_raw_bytes", "timeout_seconds"])
            func bounded(_ key: String, _ maximum: Int) throws -> Int {
                guard let value = values[key] else { return maximum }
                guard let number = value.intValue, (1...maximum).contains(number) else { throw Self.invalid("Invalid export limit: \(key).") }
                return number
            }
            limits.rows = try bounded("max_rows", limits.rows)
            limits.fileBytes = try bounded("max_file_bytes", limits.fileBytes)
            limits.rawBytes = try bounded("max_raw_bytes", limits.rawBytes)
            limits.timeoutSeconds = try bounded("timeout_seconds", limits.timeoutSeconds)
        }
        self.limits = limits
        guard let items = a["queries"]?.arrayValue, (1...20).contains(items.count) else { throw Self.invalid("Provide 1–20 queries.") }
        var names: Set<String> = []
        var sqlBytes = 0
        queries = try items.map { item in
            guard let q = item.objectValue else { throw Self.invalid("Each query must be an object.") }
            try Self.keys(q, allowed: ["name", "sql", "columns", "expected_rows"])
            let name = try q.requiredString("name"), sql = try q.requiredString("sql")
            guard !name.isEmpty, name.utf16.count <= 31, !name.hasPrefix("'"), !name.hasSuffix("'"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "\\/?*[]:".unicodeScalars.contains($0) }),
                  names.insert(name.lowercased()).inserted else { throw Self.invalid("Sheet names must be unique, valid Excel names of at most 31 UTF-16 units.") }
            sqlBytes += sql.utf8.count
            guard !sql.isEmpty, !sql.contains("\0"), sqlBytes <= 1_048_576 else { throw Self.invalid("SQL exceeds the export request budget.") }
            var columns: [MCPExportColumn]?
            if let supplied = q["columns"] {
                guard let list = supplied.arrayValue, (1...256).contains(list.count) else { throw Self.invalid("Provide 1–256 column mappings.") }
                var indexes: Set<Int> = []
                columns = try list.map { value in
                    guard let c = value.objectValue else { throw Self.invalid("Invalid column mapping.") }
                    try Self.keys(c, allowed: ["source_index", "title", "type", "date_format", "width"])
                    if let kind = c["type"], kind.stringValue == nil { throw Self.invalid("Column type must be a string.") }
                    guard let index = c["source_index"]?.intValue, (0..<256).contains(index), indexes.insert(index).inserted,
                          let title = c["title"]?.stringValue, !title.isEmpty, title.utf16.count <= 256,
                          let kind = MCPExportColumn.Kind(rawValue: c["type"]?.stringValue ?? "text") else { throw Self.invalid("Invalid source_index, title or type.") }
                    let dateFormat = c["date_format"]?.stringValue
                    if let value = c["date_format"], value.stringValue == nil { throw Self.invalid("date_format must be a string.") }
                    if let dateFormat, !["yyyy-mm-dd", "yyyy-mm-dd hh:mm:ss"].contains(dateFormat) || ![.date, .datetime].contains(kind) {
                        throw Self.invalid("date_format requires date/datetime and one of yyyy-mm-dd or yyyy-mm-dd hh:mm:ss.")
                    }
                    let width = c["width"]?.intValue
                    if c["width"] != nil, width.map({ (8...80).contains($0) }) != true { throw Self.invalid("width must be 8–80.") }
                    return MCPExportColumn(sourceIndex: index, title: title, kind: kind, dateFormat: dateFormat, width: width)
                }
            }
            let expected = q["expected_rows"]?.intValue
            if q["expected_rows"] != nil, expected.map({ (0...limits.rows).contains($0) }) != true { throw Self.invalid("Invalid expected_rows.") }
            return MCPExportQuery(name: name, sql: sql, columns: columns, expectedRows: expected)
        }
        let ext = format == .xlsx ? "xlsx" : queries.count > 1 ? "zip" : "csv"
        filename = a.string("filename") ?? "QueryCraft-export.\(ext)"
        guard filename.utf8.count <= 180, filename.hasSuffix(".\(ext)"), filename != ".", filename != "..",
              !filename.hasPrefix("."), !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Self.invalid("Use a filename only, ending in .\(ext); paths and overwrite are not supported.") }
    }

    static func keys(_ values: [String: MCPJSONValue], allowed: Set<String>) throws {
        guard Set(values.keys).isSubset(of: allowed) else { throw invalid("Unknown nested export argument.") }
    }
    static func invalid(_ message: String) -> MCPFailure { MCPFailure(message) }
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
