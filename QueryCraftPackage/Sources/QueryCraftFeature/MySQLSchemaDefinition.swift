import Foundation

/// A deliberately limited SHOW CREATE TABLE reader. Unknown clauses remain
/// visible for comparison, but never become executable migration statements.
struct MySQLSchemaDefinition: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        enum Kind: String, Sendable { case column, index, constraint }
        let kind: Kind
        let name: String
        let tokens: [String]
        var key: String { "\(kind.rawValue):\(name.lowercased())" }
        var definition: String { tokens.joined(separator: " ") }
        var canonical: [String] { tokens.map(MySQLSchemaDefinition.canonicalToken) }
        var indexName: String? {
            if kind == .index { return name }
            if tokens.count > 2, tokens[1].uppercased() == "KEY" {
                return MySQLSchemaDefinition.identifierValue(tokens[2])
            }
            return nil
        }
    }

    let parts: [Part]
    let options: [String]

    init(ddl: String, noBackslashEscapes: Bool = false) throws {
        let tokens = try Self.tokenize(ddl, noBackslashEscapes: noBackslashEscapes)
        guard tokens.count > 4,
              tokens[0].uppercased() == "CREATE",
              tokens[1].uppercased() == "TABLE",
              let start = tokens.firstIndex(of: "(")
        else { throw SchemaComparisonError.invalidDefinition }
        var depth = 1
        var segments: [[String]] = []
        var segment: [String] = []
        var closing: Int?
        for index in (start + 1)..<tokens.count {
            let token = tokens[index]
            if token == "(" { depth += 1 }
            if token == ")" { depth -= 1 }
            if depth == 0 {
                segments.append(segment)
                closing = index
                break
            }
            if token == ",", depth == 1 {
                segments.append(segment)
                segment = []
            } else {
                segment.append(token)
            }
        }
        guard let closing, !segments.isEmpty else {
            throw SchemaComparisonError.invalidDefinition
        }
        parts = try segments.map { tokens in
            guard let first = tokens.first else { throw SchemaComparisonError.invalidDefinition }
            if let name = Self.identifierValue(first) {
                return Part(kind: .column, name: name, tokens: tokens)
            }
            if first.uppercased() == "KEY", tokens.count > 2,
               let name = Self.identifierValue(tokens[1]) {
                return Part(kind: .index, name: name, tokens: tokens)
            }
            if ["UNIQUE", "FULLTEXT", "SPATIAL"].contains(first.uppercased()),
               tokens.count > 3, tokens[1].uppercased() == "KEY",
               let name = Self.identifierValue(tokens[2]) {
                return Part(kind: .constraint, name: "\(first.uppercased()):\(name)", tokens: tokens)
            }
            if first.uppercased() == "CONSTRAINT", tokens.count > 2,
               let name = Self.identifierValue(tokens[1]) {
                return Part(kind: .constraint, name: name, tokens: tokens)
            }
            if first.uppercased() == "PRIMARY" {
                return Part(kind: .constraint, name: "PRIMARY", tokens: tokens)
            }
            throw SchemaComparisonError.invalidDefinition
        }
        guard Set(parts.map(\.key)).count == parts.count else {
            throw SchemaComparisonError.invalidDefinition
        }
        // AUTO_INCREMENT is runtime state, not the column's AUTO_INCREMENT attribute.
        var tail = Array(tokens[(closing + 1)...])
        if tail.last == ";" { tail.removeLast() }
        if let index = tail.firstIndex(where: { $0.uppercased() == "AUTO_INCREMENT" }),
           index + 2 < tail.count, tail[index + 1] == "=",
           tail[index + 2].allSatisfy(\.isNumber) {
            tail.removeSubrange(index...(index + 2))
        }
        options = tail
    }

    static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    static func identifierValue(_ token: String) -> String? {
        guard token.count >= 2, token.first == "`", token.last == "`" else { return nil }
        return String(token.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
    }

    static func canonicalToken(_ token: String) -> String {
        guard let first = token.first, !["'", "\"", "`"].contains(first) else { return token }
        return token.uppercased()
    }

    static func tokenize(_ text: String, noBackslashEscapes: Bool = false) throws -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char.isWhitespace { index += 1; continue }
            let start = index
            if char == "`" || char == "'" || char == "\"" {
                index += 1
                var closed = false
                while index < characters.count {
                    if characters[index] == "\\", char != "`", !noBackslashEscapes {
                        index += 2
                    } else if characters[index] == char {
                        index += 1
                        if index < characters.count, characters[index] == char { index += 1 }
                        else { closed = true; break }
                    } else { index += 1 }
                }
                guard closed, index <= characters.count else { throw SchemaComparisonError.invalidDefinition }
            } else if char.isLetter || char.isNumber || char == "_" || char == "$" {
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                        || characters[index] == "_" || characters[index] == "$" { index += 1 }
            } else {
                // Version comments may contain real SQL. Do not silently discard them.
                if char == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    throw SchemaComparisonError.invalidDefinition
                }
                index += 1
            }
            result.append(String(characters[start..<index]))
        }
        return result
    }

    /// Only nullable primitive columns with no expression/default/charset
    /// dependencies are offered by the initial export-only planner.
    static func canAddColumn(_ part: Part) -> Bool {
        guard part.kind == .column, part.tokens.count >= 2 else { return false }
        let tokens = part.canonical
        let types = ["TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
                     "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "DATE", "DATETIME", "TIME",
                     "CHAR", "VARCHAR", "BINARY", "VARBINARY", "TEXT", "BLOB"]
        guard types.contains(tokens[1]) else { return false }
        var i = 2
        if i < tokens.count, tokens[i] == "(" {
            i += 1
            guard i < tokens.count, tokens[i].allSatisfy(\.isNumber) else { return false }
            i += 1
            if i < tokens.count, tokens[i] == "," {
                i += 1
                guard i < tokens.count, tokens[i].allSatisfy(\.isNumber) else { return false }
                i += 1
            }
            guard i < tokens.count, tokens[i] == ")" else { return false }
            i += 1
        }
        if i < tokens.count, tokens[i] == "UNSIGNED" { i += 1 }
        if i < tokens.count, tokens[i] == "NULL" { i += 1 }
        if i < tokens.count, tokens[i] == "DEFAULT" {
            i += 1
            guard i < tokens.count, tokens[i] == "NULL" else { return false }
            i += 1
        }
        if i < tokens.count, tokens[i] == "COMMENT" {
            i += 1
            guard i < tokens.count, tokens[i].first == "'" else { return false }
            i += 1
        }
        return i == tokens.count
    }

    static func simpleIndexColumns(_ part: Part) -> [String]? {
        guard part.kind == .index, part.tokens.count >= 5,
              part.tokens[2] == "(", part.tokens.last == ")" else { return nil }
        let tokens = Array(part.tokens[3..<part.tokens.count - 1])
        var names: [String] = []
        var index = 0
        while index < tokens.count {
            guard let name = identifierValue(tokens[index]) else { return nil }
            names.append(name)
            index += 1
            if index < tokens.count, tokens[index].uppercased() == "ASC" { index += 1 }
            if index == tokens.count { break }
            guard tokens[index] == ",", index + 1 < tokens.count else { return nil }
            index += 1
        }
        return names.isEmpty ? nil : names
    }
}

enum SchemaComparisonError: LocalizedError {
    case invalidDefinition, unsupportedServer, sameDatabase, invalidDatabase

    var errorDescription: String? {
        switch self {
        case .invalidDefinition:
            AppCopy.current.text("此对象的定义需要手动审查，请查看原始 DDL。", "This definition requires manual DDL review.")
        case .unsupportedServer:
            AppCopy.current.text("当前服务器不支持结构比较。支持 MySQL 5.7、8.0 和 8.4。", "Choose a MySQL 5.7, 8.0 or 8.4 server.")
        case .sameDatabase:
            AppCopy.current.text("源和目标指向同一个服务器上的同一数据库。", "Source and target refer to the same database on the same server.")
        case .invalidDatabase:
            AppCopy.current.text("数据库不存在或当前账号无权读取。请检查数据库名称。", "Database unavailable. Check its name and your metadata permissions.")
        }
    }
}
