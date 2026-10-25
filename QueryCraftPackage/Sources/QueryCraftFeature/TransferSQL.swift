#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

enum TransferSQL {
    struct Token {
        let value: String
        let range: Range<String.Index>
        let identifier: Bool
    }

    static func dialect(_ type: DatabaseType) -> WorkspaceSQLExportDialect {
        type == .postgresql ? .postgresql : type == .doris ? .doris : .mysql
    }
    static func qualified(_ endpoint: TransferEndpoint, _ name: String, type: DatabaseType) -> String {
        let quote = dialect(type).identifier
        return [endpoint.namespace, name].map(quote).joined(separator: ".")
    }
    // A review label, not executable SQL: PostgreSQL includes the database as well as the schema.
    static func previewQualified(_ endpoint: TransferEndpoint, _ name: String, type: DatabaseType) -> String {
        let location = type == .postgresql ? [endpoint.database, endpoint.schema] : [endpoint.database]
        return (location.filter { !$0.isEmpty } + [name])
            .map(dialect(type).identifier).joined(separator: ".")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    static func string(_ text: String, type: DatabaseType) throws -> String { try dialect(type).literal(.text(text)) }

    // Tokenize identifiers without touching literals, comments or dollar-quoted routine bodies.
    static func tokens(_ sql: String, rejectExecutableComments: Bool = false) throws -> [Token] {
        var result: [Token] = [], index = sql.startIndex
        func advance(_ i: String.Index) -> String.Index { sql.index(after: i) }
        while index < sql.endIndex {
            let start = index, char = sql[index]
            if char.isWhitespace { index = advance(index); continue }
            let suffix = sql[index...]
            if suffix.hasPrefix("--") || char == "#" {
                index = suffix.firstIndex(of: "\n") ?? sql.endIndex; continue
            }
            if suffix.hasPrefix("/*") {
                if rejectExecutableComments && (suffix.hasPrefix("/*!") || suffix.uppercased().hasPrefix("/*M!")) {
                    throw TransferFailure("过滤不允许可执行的版本注释。", "Executable version comments are not allowed in filters.")
                }
                guard let end = suffix.range(of: "*/")?.upperBound else { throw TransferFailure("SQL 注释未闭合。", "Unterminated SQL comment.") }
                index = end; continue
            }
            if char == "$", let match = suffix.range(of: #"^\$[A-Za-z_0-9]*\$"#, options: .regularExpression) {
                let delimiter = String(sql[match]); index = match.upperBound
                guard let end = sql[index...].range(of: delimiter)?.upperBound else { throw TransferFailure("SQL 字符串未闭合。", "Unterminated SQL string.") }
                index = end; continue
            }
            if char == "'" || char == "\"" || char == "`" {
                index = advance(index); var value = "", closed = false
                while index < sql.endIndex {
                    let current = sql[index]; index = advance(index)
                    if current == char {
                        if index < sql.endIndex && sql[index] == char { value.append(char); index = advance(index) }
                        else { closed = true; break }
                    } else if current == "\\" && char == "'" && index < sql.endIndex {
                        value.append(current); value.append(sql[index]); index = advance(index)
                    } else { value.append(current) }
                }
                guard closed else { throw TransferFailure("SQL 引号未闭合。", "Unterminated SQL quote.") }
                if char != "'" { result.append(Token(value: value, range: start..<index, identifier: true)) }
                continue
            }
            if char.isLetter || char == "_" || char.isNumber {
                index = advance(index)
                while index < sql.endIndex && (sql[index].isLetter || sql[index].isNumber || sql[index] == "_" || sql[index] == "$") { index = advance(index) }
                result.append(Token(value: String(sql[start..<index]), range: start..<index, identifier: true))
            } else {
                index = advance(index); result.append(Token(value: String(char), range: start..<index, identifier: false))
            }
        }
        return result
    }

    static func validateFilter(_ filter: String) throws {
        guard !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let words = try tokens(filter, rejectExecutableComments: true)
        let forbidden: Set<String> = ["INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE", "TRUNCATE", "CALL", "COPY", "INTO", "FOR", "LOCK", "COMMIT", "ROLLBACK", "SET", "DO", "EXECUTE", "LOAD", "GRANT", "REVOKE"]
        guard !words.contains(where: { $0.value == ";" || forbidden.contains($0.value.uppercased()) && !["\"", "`"].contains(String(filter[$0.range].prefix(1))) }) else {
            throw TransferFailure("过滤仅允许单个只读 SELECT 或 WHERE 条件，不允许写入、锁定和多条语句。", "Filters allow one read-only SELECT or WHERE predicate, without writes, locking or multiple statements.")
        }
        let first = words.first?.value.uppercased()
        if first == "WITH" { throw TransferFailure("完整查询过滤请使用 SELECT；WITH 查询请包装为子查询。", "Use SELECT for a full-query filter; wrap WITH queries in a subquery.") }
    }

    // A single exact numeric primary key supports indexed forward reads. Composite,
    // generated, floating-point and keyless tables retain the existing snapshot paging.
    // A full SELECT may duplicate its source key through joins, so it must also retain OFFSET.
    static func paginationKey(columns: [WorkspaceDatabaseColumn], type: DatabaseType, filter: String) throws -> WorkspaceDatabaseColumn? {
        guard type == .mysql || type == .postgresql,
              try tokens(filter.trimmingCharacters(in: .whitespacesAndNewlines)).first?.value.uppercased() != "SELECT" else { return nil }
        let keys = columns.filter { $0.key == "PRI" }
        guard keys.count == 1, let key = keys.first, !key.isGenerated, !key.isNullable else { return nil }
        let base = key.type.lowercased().split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? ""
        return ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric"].contains(base) ? key : nil
    }

    static func select(object: TransferObject, columns: [WorkspaceDatabaseColumn], endpoint: TransferEndpoint,
                       type: DatabaseType, filter: String, order: [String], offset: Int, limit: Int?,
                       paginationKey: WorkspaceDatabaseColumn? = nil, after: String? = nil, preserveOrder: Bool = false) throws -> String {
        try validateFilter(filter)
        let d = dialect(type), quote = d.identifier
        let fields = columns.map { column -> String in
            let name = quote(column.name)
            return type != .postgresql && isBinary(column.type) ? "HEX(\(name)) AS \(name)" : name
        }.joined(separator: ", ")
        var predicate = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullQuery = try tokens(predicate).first?.value.uppercased() == "SELECT"
        let from = fullQuery ? "(\(predicate)) AS querycraft_transfer_source" : qualified(endpoint, object.name, type: type)
        if predicate.uppercased().hasPrefix("WHERE ") { predicate = String(predicate.dropFirst(6)) }
        var predicates = predicate.isEmpty || fullQuery ? [] : ["(\(predicate))"]
        if let paginationKey, let after {
            // Numeric literals must stay exact: comparing a BIGINT with a quoted
            // string can coerce both to Double in MySQL and skip IDs above 2^53.
            guard after.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else {
                throw TransferFailure("来源主键不是有效的精确数值。", "The source primary key is not an exact numeric value.")
            }
            predicates.append("\(quote(paginationKey.name)) > \(after)")
        }
        let whereSQL = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        // A repeatable snapshot plus a total ordering prevents missing/duplicate pages.
        let ordering = order.isEmpty ? columns.map { column in
            type == .postgresql ? "\(quote(column.name))::text COLLATE \"C\"" : "HEX(CAST(\(quote(column.name)) AS \(type == .doris ? "STRING" : "BINARY")))"
        } : order.map(quote)
        let orderSQL = ordering.isEmpty || limit == nil && !preserveOrder ? "" : " ORDER BY " + ordering.joined(separator: ", ")
        let paging = limit.map { " LIMIT \($0)" + (paginationKey == nil ? " OFFSET \(offset)" : "") } ?? ""
        return "SELECT \(fields) FROM \(from)\(whereSQL)\(orderSQL)\(paging)"
    }

    static func isBinary(_ type: String, databaseType: DatabaseType? = nil) -> Bool {
        let base = type.lowercased().split(separator: "(").first.map(String.init) ?? ""
        if databaseType == .postgresql { return base == "bytea" }
        return ["binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "geometry", "bytea"].contains(base)
    }

    static func literal(_ value: WorkspaceDatabaseDataCell, source: WorkspaceDatabaseColumn,
                        sourceType: DatabaseType, target: WorkspaceDatabaseColumn, targetType: DatabaseType) throws -> String {
        try CellEncoder(source: source, sourceType: sourceType, target: target, targetType: targetType).encode(value)
    }

    struct CellEncoder: Sendable {
        private enum Encoding: Sendable {
            case binary(sourceIsPostgres: Bool, targetIsPostgres: Bool, targetIsBinary: Bool)
            case boolean(String)
            case postgresBooleanToMySQL
            case text(WorkspaceSQLExportDialect)
        }
        private let encoding: Encoding

        init(source: WorkspaceDatabaseColumn, sourceType: DatabaseType, target: WorkspaceDatabaseColumn, targetType: DatabaseType) {
            let targetName = target.type.lowercased()
            if isBinary(source.type, databaseType: sourceType) {
                encoding = .binary(sourceIsPostgres: sourceType == .postgresql, targetIsPostgres: targetType == .postgresql,
                                   targetIsBinary: isBinary(target.type, databaseType: targetType))
            } else if targetName == "boolean" || targetName == "bool" {
                encoding = .boolean(source.name)
            } else if targetType == .mysql && (source.type == "boolean" || source.type == "bool") {
                encoding = .postgresBooleanToMySQL
            } else { encoding = .text(dialect(targetType)) }
        }

        func encode(_ value: WorkspaceDatabaseDataCell) throws -> String {
            if value == .null { return "NULL" }
            guard case var .text(text) = value else { throw WorkspaceDataExportError.incompleteBinaryValue }
            switch encoding {
            case let .binary(sourceIsPostgres, targetIsPostgres, targetIsBinary):
                if sourceIsPostgres {
                    guard text.hasPrefix("\\x") else { throw WorkspaceDataExportError.incompleteBinaryValue }
                    text = String(text.dropFirst(2))
                }
                guard targetIsBinary, text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                    throw TransferFailure("二进制字段需要可保留原始字节的目标类型。", "Binary columns require a target type that preserves original bytes.")
                }
                if text.utf8.count % 2 != 0 { text = "0" + text }
                return targetIsPostgres ? "decode('\(text)','hex')" : "X'\(text)'"
            case let .boolean(name):
                switch text.lowercased() {
                case "1", "t", "true": return "TRUE"
                case "0", "f", "false": return "FALSE"
                default: throw TransferFailure("布尔值无法无损转换：\(name)。", "Cannot losslessly convert boolean column: \(name).")
                }
            case .postgresBooleanToMySQL:
                if text == "t" || text == "true" { text = "1" }
                if text == "f" || text == "false" { text = "0" }
                return try WorkspaceSQLExportDialect.mysql.literal(.text(text))
            case let .text(dialect): return try dialect.literal(.text(text))
            }
        }
    }

    static func insert(rows: [WorkspaceDatabaseDataRow], columns: [WorkspaceDatabaseColumn],
                       targetColumns: [WorkspaceDatabaseColumn], sourceType: DatabaseType, targetType: DatabaseType,
                       endpoint: TransferEndpoint, name: String, strategy: TransferStrategy, keys: [String]) throws -> String {
        try InsertEncoder(columns: columns, targetColumns: targetColumns, sourceType: sourceType, targetType: targetType,
                          endpoint: endpoint, name: name, strategy: strategy, keys: keys).statement(rows: rows)
    }

    // Compute metadata-dependent work once per table and reuse it for every batch.
    struct InsertEncoder: Sendable {
        private let prefix: String
        private let suffix: String
        private let cells: [CellEncoder]

        init(columns: [WorkspaceDatabaseColumn], targetColumns: [WorkspaceDatabaseColumn], sourceType: DatabaseType,
             targetType: DatabaseType, endpoint: TransferEndpoint, name: String, strategy: TransferStrategy, keys: [String]) throws {
            let quote = dialect(targetType).identifier
            let byName = Dictionary(uniqueKeysWithValues: targetColumns.map { ($0.name, $0) })
            guard columns.allSatisfy({ byName[$0.name] != nil }) else { throw TransferFailure("目标字段与来源不兼容。", "Target columns are incompatible with the source.") }
            cells = columns.map { CellEncoder(source: $0, sourceType: sourceType, target: byName[$0.name]!, targetType: targetType) }
            let identity = targetType == .postgresql && columns.contains { byName[$0.name]?.extra.contains("IDENTITY") == true } ? " OVERRIDING SYSTEM VALUE" : ""
            prefix = "INSERT INTO \(qualified(endpoint, name, type: targetType)) (\(columns.map { quote($0.name) }.joined(separator: ", ")))\(identity) VALUES "
            suffix = try TransferSQL.conflictClause(columns: columns, keys: keys, type: targetType, strategy: strategy)
        }

        func statement<Rows: Collection>(rows: Rows) throws -> String where Rows.Element == WorkspaceDatabaseDataRow {
            var sql = prefix
            sql.reserveCapacity(prefix.utf8.count + min(1_048_576, rows.count * cells.count * 24))
            var first = true
            for row in rows {
                guard row.values.count == cells.count else { throw TransferFailure("读取结果字段数量发生变化。", "The source result column count changed.") }
                if !first { sql += ",\n" }; first = false
                sql += "("
                for index in cells.indices {
                    if index != 0 { sql += ", " }
                    sql += try cells[index].encode(row.values[index])
                }
                sql += ")"
            }
            sql += suffix
            return sql
        }
    }

    static func conflictClause(columns: [WorkspaceDatabaseColumn], keys: [String], type: DatabaseType, strategy: TransferStrategy) throws -> String {
            let quote = dialect(type).identifier
            var ending = ""
            if strategy == .upsert {
                guard !keys.isEmpty else { throw TransferFailure("Upsert 需要目标主键。", "Upsert requires a target primary key.") }
                let updates = columns.filter { !keys.contains($0.name) }.map(\.name)
                if type == .postgresql {
                    ending = " ON CONFLICT (" + keys.map(quote).joined(separator: ", ") + ") "
                    ending += updates.isEmpty ? "DO NOTHING" : "DO UPDATE SET " + updates.map { "\(quote($0)) = EXCLUDED.\(quote($0))" }.joined(separator: ", ")
                } else {
                    let names = updates.isEmpty ? keys : updates
                    ending = " ON DUPLICATE KEY UPDATE " + names.map { "\(quote($0)) = VALUES(\(quote($0)))" }.joined(separator: ", ")
                }
            }
            return ending
    }

    static func rewriteQualified(_ sql: String, sourceNamespace: String, targetNamespace: String,
                                 tableNames: [String: String], type: DatabaseType) throws -> String {
        let parts = try tokens(sql), quote = dialect(type).identifier
        var replacements: [(Range<String.Index>, String)] = []
        for index in parts.indices where parts[index].identifier {
            if index + 2 < parts.count, parts[index].value == sourceNamespace, parts[index + 1].value == ".", parts[index + 2].identifier {
                replacements.append((parts[index].range, quote(targetNamespace)))
                let previous = index > 0 ? parts[index - 1].value.uppercased() : ""
                let relationContext = ["FROM", "JOIN", "REFERENCES", "TABLE", "ON", "UPDATE", "INTO", "SETOF"].contains(previous)
                    || index + 3 < parts.count && parts[index + 3].value == "."
                if relationContext, let name = tableNames[parts[index + 2].value] { replacements.append((parts[index + 2].range, quote(name))) }
            }
        }
        var result = sql
        for (range, replacement) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { result.replaceSubrange(range, with: replacement) }
        return result
    }

    static func retargetCreate(_ sql: String, keyword: String, target: String) throws -> String {
        let parts = try tokens(sql)
        guard let position = parts.firstIndex(where: { $0.value.uppercased() == keyword && !["\"", "`"].contains(String(sql[$0.range].prefix(1))) }), position + 1 < parts.count else {
            throw TransferFailure("无法安全定位建表或对象定义。", "Cannot safely locate the CREATE object identifier.")
        }
        var start = position + 1
        if parts[start].value.uppercased() == "IF" { start += 3 }
        guard start < parts.count, parts[start].identifier else { throw TransferFailure("对象定义缺少名称。", "The object definition has no identifier.") }
        var end = start
        if start + 2 < parts.count && parts[start + 1].value == "." { end += 2 }
        var result = sql
        result.replaceSubrange(parts[start].range.lowerBound..<parts[end].range.upperBound, with: target)
        return result
    }
}
