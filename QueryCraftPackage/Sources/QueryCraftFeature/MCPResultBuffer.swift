import Foundation
import MCP

actor MCPResultBuffer {
    private var columns: [WorkspaceDatabaseDataColumn] = []
    private var rows: [Value] = []
    private var byteCount = 0
    private var truncated = false
    private let limit: Int
    private let byteLimit: Int
    private let cellOffset: Int
    private let cellLimit: Int
    init(limit: Int, byteLimit: Int, cellOffset: Int = 0, cellLimit: Int = 200) {
        self.limit = limit; self.byteLimit = byteLimit
        self.cellOffset = min(1_000_000, max(0, cellOffset)); self.cellLimit = min(65536, max(1, cellLimit))
    }
    func append(_ batch: WorkspaceDatabaseDataBatch) throws {
        try Task.checkCancellation()
        columns = batch.columns
        for row in batch.rows {
            guard rows.count < limit else { truncated = true; break }
            let cells: [Value] = row.values.map { cell in
                switch cell {
                case .null: return .null
                case .binary(let count, let preview):
                    return .object(["binary_bytes": .int(count), "preview_base64": .string(Data(preview).base64EncodedString()), "truncated": .bool(count > preview.count)])
                case .text(let value):
                    let start = value.index(value.startIndex, offsetBy: cellOffset, limitedBy: value.endIndex) ?? value.endIndex
                    let end = value.index(start, offsetBy: cellLimit, limitedBy: value.endIndex) ?? value.endIndex
                    if start != value.startIndex || end != value.endIndex {
                        return .object(["text": .string(String(value[start..<end])), "offset": .int(cellOffset), "next_offset": end == value.endIndex ? .null : .int(cellOffset + value[start..<end].count), "truncated": .bool(end != value.endIndex)])
                    }
                    return .string(value)
                }
            }
            let entry = Value.array(cells)
            let size = try JSONEncoder().encode(entry).count
            guard byteCount + size <= byteLimit else { truncated = true; break }
            byteCount += size; rows.append(entry)
        }
    }
    func value(hasMore: Bool = false) -> Value {
        .object(["columns": .array(columns.map { .object(["name": .string($0.name), "type": $0.type.map(Value.string) ?? .null]) }),
                 "rows": .array(rows), "returned_rows": .int(rows.count), "truncated": .bool(truncated || hasMore)])
    }
}

extension Dictionary where Key == String, Value == MCP.Value {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else { throw MCPFailure("Missing or invalid argument: \(key)") }
        return value
    }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func integer(_ key: String, default value: Int) -> Int { self[key]?.intValue ?? value }
    func flag(_ key: String) -> Bool { self[key]?.boolValue ?? false }
}
