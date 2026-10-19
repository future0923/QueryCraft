import Foundation

/// Lossless MySQL DDL slices. Unlike the original restricted first-increment
/// parser this retains expressions, generated columns and version comments.
struct SchemaComparisonDDL: Sendable {
    struct Token: Sendable {
        let text: String
        let range: Range<String.Index>
        var keyword: String { text.uppercased() }
        var identifier: String {
            text.first == "`" && text.last == "`" ? String(text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`") : text
        }
    }
    struct Clause: Sendable { let name: String; let kind: String; let sql: String }
    let sql: String
    let clauses: [Clause]
    let suffix: String
    init(_ sql: String, noBackslashEscapes: Bool = false) throws {
        self.sql = sql
        let tokens = try Self.tokens(sql, noBackslashEscapes: noBackslashEscapes)
        guard let open = tokens.firstIndex(where: { $0.text == "(" }) else { throw SchemaComparisonError.invalidDefinition }
        var depth = 0, start = tokens[open].range.upperBound
        var slices: [Substring] = [], closing: String.Index?
        for token in tokens[open...] {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            if depth == 0 { slices.append(sql[start..<token.range.lowerBound]); closing = token.range.upperBound; break }
            if depth == 1 && token.text == "," { slices.append(sql[start..<token.range.lowerBound]); start = token.range.upperBound }
        }
        guard let closing else { throw SchemaComparisonError.invalidDefinition }
        clauses = try slices.map { slice in
            let clause = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = try Self.tokens(clause, noBackslashEscapes: noBackslashEscapes)
            guard let first = t.first else { throw SchemaComparisonError.invalidDefinition }
            let tableClauseKeywords: Set<String> = ["PRIMARY", "KEY", "INDEX", "UNIQUE", "FULLTEXT", "SPATIAL", "CONSTRAINT", "CHECK"]
            if first.text.first == "`" || !tableClauseKeywords.contains(first.keyword) {
                return Clause(name: first.identifier, kind: "column", sql: clause)
            }
            let words = t.map(\.keyword)
            if first.keyword == "PRIMARY" { return Clause(name: "PRIMARY", kind: "index", sql: clause) }
            if ["KEY", "INDEX", "UNIQUE", "FULLTEXT", "SPATIAL"].contains(first.keyword) {
                let n = ["KEY", "INDEX"].contains(first.keyword) ? 1 : 2
                guard t.indices.contains(n) else { throw SchemaComparisonError.invalidDefinition }
                return Clause(name: t[n].identifier, kind: "index", sql: clause)
            }
            if first.keyword == "CONSTRAINT", t.count > 2 {
                return Clause(name: t[1].identifier, kind: words.contains("FOREIGN") ? "foreignKey" : words.contains("CHECK") ? "check" : "constraint", sql: clause)
            }
            if first.keyword == "CHECK" { return Clause(name: clause, kind: "check", sql: clause) }
            throw SchemaComparisonError.invalidDefinition
        }
        suffix = String(sql[closing...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
    }
    func clause(_ kind: String, _ name: String) -> String? { clauses.first { $0.kind == kind && $0.name == name }?.sql }
    func create(database: String, name: String, omittingForeignKeys: Bool = false) -> String {
        "CREATE TABLE \(Self.qualified(database, name)) (\n  " + clauses.filter { !omittingForeignKeys || $0.kind != "foreignKey" }.map(\.sql).joined(separator: ",\n  ") + "\n) " + suffix
    }
    static func qualified(_ database: String, _ name: String) -> String { identifier(database) + "." + identifier(name) }
    static func identifier(_ name: String) -> String { MySQLSchemaDefinition.identifier(name) }
    static func tokens(_ sql: String, noBackslashEscapes: Bool = false) throws -> [Token] {
        var tokens: [Token] = [], i = sql.startIndex
        func next(_ i: String.Index) -> String.Index { sql.index(after: i) }
        while i < sql.endIndex {
            if sql[i].isWhitespace { i = next(i); continue }
            let start = i, char = sql[i]
            if ["`", "'", "\""].contains(char) {
                i = next(i); var closed = false
                while i < sql.endIndex {
                    if sql[i] == "\\", char != "`", !noBackslashEscapes {
                        i = next(i); if i < sql.endIndex { i = next(i) }; continue
                    }
                    if sql[i] == char {
                        i = next(i)
                        if i < sql.endIndex && sql[i] == char { i = next(i); continue }
                        closed = true; break
                    }
                    i = next(i)
                }
                guard closed else { throw SchemaComparisonError.invalidDefinition }
            } else if char == "/", next(i) < sql.endIndex, sql[next(i)] == "*" {
                i = sql.index(i, offsetBy: 2)
                guard let end = sql.range(of: "*/", range: i..<sql.endIndex) else { throw SchemaComparisonError.invalidDefinition }
                i = end.upperBound
            } else if char == "#" || (char == "-" && next(i) < sql.endIndex && sql[next(i)] == "-" && (sql.index(i, offsetBy: 2) == sql.endIndex || sql[sql.index(i, offsetBy: 2)].isWhitespace)) {
                while i < sql.endIndex, sql[i] != "\n" { i = next(i) }
            } else if char.isLetter || char.isNumber || char == "_" || char == "$" {
                i = next(i)
                while i < sql.endIndex, sql[i].isLetter || sql[i].isNumber || sql[i] == "_" || sql[i] == "$" { i = next(i) }
            } else { i = next(i) }
            tokens.append(.init(text: String(sql[start..<i]), range: start..<i))
        }
        return tokens
    }
    static func canonical(_ sql: String) -> [String] {
        (try? tokens(sql).map { token in
            ["'", "\"", "`"].contains(token.text.first) || token.text.hasPrefix("/*") ? token.text : token.keyword
        }) ?? [sql]
    }
    /// Replace only the declared object's name. Never replace matching text in
    /// string literals, comments, expressions or stored-program bodies.
    static func retarget(_ sql: String, kind: String, database: String, name: String) throws -> String {
        let tokens = try tokens(sql)
        guard let keyword = tokens.firstIndex(where: { $0.keyword == kind.uppercased() }) else { throw SchemaComparisonError.invalidDefinition }
        var i = keyword + 1
        while i < tokens.count, ["IF", "NOT", "EXISTS"].contains(tokens[i].keyword) { i += 1 }
        guard i < tokens.count else { throw SchemaComparisonError.invalidDefinition }
        var end = i
        if tokens.indices.contains(i + 2), tokens[i + 1].text == "." { end = i + 2 }
        return sql.replacingCharacters(in: tokens[i].range.lowerBound..<tokens[end].range.upperBound, with: qualified(database, name))
    }
}
