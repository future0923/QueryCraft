#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

/// COPY text / LOCAL TSV share the same escaped byte framing. Binary fields use
/// validated hexadecimal; PostgreSQL gets its bytea prefix and MySQL uses UNHEX.
/// No floating point conversion, SQL literal building, or filesystem staging.
struct TransferBulkEncoder: Sendable {
    private enum Cell: Sendable { case text, binary(Bool), boolean, mysqlBoolean }
    let sql: String
    let token: String
    private let format: WorkspaceNativeBulkFormat
    private let cells: [Cell]

    init(columns: [WorkspaceDatabaseColumn], targetColumns: [WorkspaceDatabaseColumn],
         sourceType: DatabaseType, targetType: DatabaseType, endpoint: TransferEndpoint,
         name: String, format: WorkspaceNativeBulkFormat) throws {
        self.format = format
        token = "querycraft-memory-" + UUID().uuidString.lowercased()
        let targets = Dictionary(uniqueKeysWithValues: targetColumns.map { ($0.name, $0) })
        let encodings: [Cell] = try columns.map { column in
            guard let target = targets[column.name], !target.isGenerated else {
                throw TransferFailure("目标字段与来源不兼容。", "Target columns are incompatible with the source.")
            }
            if TransferSQL.isBinary(column.type, databaseType: sourceType) {
                guard TransferSQL.isBinary(target.type, databaseType: targetType) else {
                    throw TransferFailure("二进制字段需要保留原始字节的目标类型。", "Binary columns require a target type that preserves original bytes.")
                }
                return .binary(sourceType == .postgresql)
            }
            if ["boolean", "bool"].contains(target.type.lowercased()) { return .boolean }
            if targetType == .mysql && ["boolean", "bool"].contains(column.type.lowercased()) { return .mysqlBoolean }
            return .text
        }
        cells = encodings
        let quote = TransferSQL.dialect(targetType).identifier
        let table = TransferSQL.qualified(endpoint, name, type: targetType)
        switch format {
        case .postgresqlCopyText:
            sql = "COPY \(table) (\(columns.map { quote($0.name) }.joined(separator: ", "))) FROM STDIN WITH (FORMAT text, ENCODING 'UTF8')"
        case .mysqlLocalTSV:
            // Hexadecimal delimiter literals work under either SQL backslash mode.
            let inputs = columns.indices.map { index -> String in "@qc_\(index)" }.joined(separator: ", ")
            let assignments = columns.indices.map { index -> String in
                let value: String
                if case .binary = encodings[index] { value = "UNHEX(@qc_\(index))" }
                else { value = "@qc_\(index)" }
                return "\(quote(columns[index].name)) = \(value)"
            }.joined(separator: ", ")
            sql = "LOAD DATA LOCAL INFILE '\(token)' INTO TABLE \(table) CHARACTER SET utf8mb4 FIELDS TERMINATED BY X'09' ESCAPED BY X'5c' LINES TERMINATED BY X'0a' (\(inputs)) SET \(assignments)"
        }
    }

    /// Emit bounded chunks even for a very wide single row. The framing protocol
    /// allows a field, UTF-8 sequence, or escape to span network chunks.
    func send(rows: [WorkspaceDatabaseDataRow], to stream: WorkspaceNativeBulkStream) async throws {
        var bytes = [UInt8](); bytes.reserveCapacity(256 * 1024)
        for row in rows {
            try Task.checkCancellation()
            guard row.values.count == cells.count else {
                throw TransferFailure("读取结果字段数量发生变化。", "The source result column count changed.")
            }
            for index in cells.indices {
                if index != 0 { bytes.append(9) }
                if row.values[index] == .null { bytes.append(contentsOf: [92, 78]); continue }
                guard case .text(var text) = row.values[index] else { throw WorkspaceDataExportError.incompleteBinaryValue }
                switch cells[index] {
                case .binary(let postgres):
                    if postgres {
                        guard text.hasPrefix("\\x") else { throw WorkspaceDataExportError.incompleteBinaryValue }
                        text = String(text.dropFirst(2))
                    }
                    guard text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                        throw WorkspaceDataExportError.incompleteBinaryValue
                    }
                    if text.utf8.count % 2 != 0 { text = "0" + text }
                    if case .postgresqlCopyText = format { bytes.append(contentsOf: [92, 92, 120]) }
                case .boolean:
                    switch text.lowercased() {
                    case "1", "t", "true": text = "1"
                    case "0", "f", "false": text = "0"
                    default: throw TransferFailure("布尔值无法无损转换。", "Cannot losslessly convert a boolean value.")
                    }
                case .mysqlBoolean:
                    if text == "t" || text == "true" { text = "1" }
                    if text == "f" || text == "false" { text = "0" }
                case .text: break
                }
                for byte in text.utf8 {
                    switch byte {
                    case 0:
                        if case .postgresqlCopyText = format { throw WorkspaceDataExportError.unsupportedSQLValue }
                        bytes.append(contentsOf: [92, 48])
                    case 8: bytes.append(contentsOf: [92, 98])
                    case 9: bytes.append(contentsOf: [92, 116])
                    case 10: bytes.append(contentsOf: [92, 110])
                    case 13: bytes.append(contentsOf: [92, 114])
                    case 26:
                        if case .mysqlLocalTSV = format { bytes.append(contentsOf: [92, 90]) }
                        else { bytes.append(byte) }
                    case 92: bytes.append(contentsOf: [92, 92])
                    default: bytes.append(byte)
                    }
                    if bytes.count >= 256 * 1024 {
                        try await stream.send(Data(bytes)); bytes.removeAll(keepingCapacity: true)
                    }
                }
            }
            bytes.append(10)
            if bytes.count >= 256 * 1024 {
                try await stream.send(Data(bytes)); bytes.removeAll(keepingCapacity: true)
            }
        }
        if !bytes.isEmpty { try await stream.send(Data(bytes)) }
    }
}
