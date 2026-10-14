import Foundation

/// Display-only recovery for tokens the shared grammar splits or omits.
/// Never used for statement boundaries, execution safety, formatting or completion.
enum SQLLexicalHighlightRecovery {
    private static let columnTypes: Set<String> = [
        "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT", "LARGEINT", "INT128",
        "FLOAT", "DOUBLE", "REAL", "DECIMAL", "DECIMALV2", "DECIMALV3", "NUMERIC", "DEC",
        "BOOLEAN", "BOOL", "BIT", "DATE", "DATEV2", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "DATETIMEV2", "YEAR",
        "CHAR", "CHARACTER", "VARCHAR", "NCHAR", "NVARCHAR", "STRING", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
        "BINARY", "VARBINARY", "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "BYTEA",
        "JSON", "JSONB", "VARIANT", "ARRAY", "MAP", "STRUCT", "BITMAP", "HLL", "QUANTILE_STATE",
        "UUID", "SERIAL", "SMALLSERIAL", "BIGSERIAL", "ENUM", "SET", "IPV4", "IPV6"
    ]
    struct Token {
        let text: String
        let range: NSRange
        let kind: SQLSyntaxHighlight.Kind?
        var upper: String { text.uppercased() }
        var isQuoted: Bool { text.hasPrefix("\"") || text.hasPrefix("`") }
        var isWord: Bool {
            isQuoted || (kind == nil && text.first.map { $0.isLetter || $0 == "_" || $0 == "$" } == true)
        }
    }

    // Order matters: comments and quoted content are opaque, so fake SQL and numbers
    // inside them cannot generate recovery. Dollar tags are case-sensitive.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?<comment>--(?=\s|$)[^\r\n]*|#[^\r\n]*|/\*[\s\S]*?(?:\*/|$))|(?<dollar>\$(?<tag>[A-Za-z_][A-Za-z_0-9]*|)\$[\s\S]*?(?:\$\k<tag>\$|$))|(?<string>(?:[eEnNbBxX]|[uU]&)?'(?:''|\\[\s\S]|[^'\\])*(?:'|$))|(?<quoted>"(?:""|[^"])*(?:"|$)|`(?:``|[^`])*(?:`|$))|(?<number>(?<![\p{L}\p{N}_$])(?:0[xX][0-9a-fA-F]+(?:_[0-9a-fA-F]+)*|0[bB][01]+(?:_[01]+)*|0[oO][0-7]+(?:_[0-7]+)*|(?:[0-9]+(?:_[0-9]+)*(?:\.[0-9]*(?:_[0-9]+)*)?|\.[0-9]+(?:_[0-9]+)*)(?:[eE][+-]?[0-9]+(?:_[0-9]+)*)?)(?![\p{L}\p{N}_$]))|[\p{L}_$][\p{L}\p{N}_$]*|->>|->|::|[^\s]"#)

    static func tokens(in source: String) -> [Token] {
        let ns = source as NSString
        return pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).map { match in
            let kind: SQLSyntaxHighlight.Kind?
            if match.range(withName: "comment").location != NSNotFound { kind = .comment }
            else if match.range(withName: "dollar").location != NSNotFound
                || match.range(withName: "string").location != NSNotFound { kind = .string }
            else if match.range(withName: "number").location != NSNotFound { kind = .number }
            else { kind = nil }
            return Token(text: ns.substring(with: match.range), range: match.range, kind: kind)
        }
    }

    static func highlights(in source: String) -> [SQLIndexHighlightRecovery.Correction] {
        let tokens = tokens(in: source)
        var result: [SQLIndexHighlightRecovery.Correction] = []
        func append(_ token: Token, _ kind: SQLSyntaxHighlight.Kind) {
            result.append(.init(highlight: .init(range: .init(token.range), kind: kind), preservesExistingSyntax: false))
        }
        for token in tokens {
            // The AST may split uppercase exponents or stop parsing before a comment/string.
            if let kind = token.kind { append(token, kind) }
            else if ["+", "-"].contains(token.text) { append(token, .operator) }
        }
        var statement: [Token] = []
        for token in tokens where token.kind != .comment {
            if token.text == ";" {
                recoverDDL(statement, append: append)
                statement.removeAll(keepingCapacity: true)
            } else { statement.append(token) }
        }
        recoverDDL(statement, append: append)
        // A token may be recognized both lexically and inside a Doris clause.
        var unique: [SQLSourceRange: SQLIndexHighlightRecovery.Correction] = [:]
        for correction in result { unique[correction.highlight.range] = correction }
        return unique.values.sorted { $0.highlight.range.location < $1.highlight.range.location }
    }

    private static func recoverDDL(_ tokens: [Token], append: (Token, SQLSyntaxHighlight.Kind) -> Void) {
        guard tokens.count > 3, ["CREATE", "ALTER"].contains(tokens[0].upper), tokens[1].upper == "TABLE" else { return }
        for index in tokens.indices where tokens[index].upper == "CONSTRAINT" && tokens[index].kind == nil {
            if index + 1 < tokens.count, tokens[index + 1].isWord { append(tokens[index + 1], .type) }
        }
        for index in tokens.indices where tokens[index].kind == nil {
            if tokens[index].upper == "FOREIGN", index + 1 < tokens.count, tokens[index + 1].upper == "KEY" {
                append(tokens[index], .keyword)
                append(tokens[index + 1], .keyword)
            }
            guard tokens[index].upper == "REFERENCES", index + 1 < tokens.count, tokens[index + 1].isWord else { continue }
            append(tokens[index], .keyword)
            var cursor = index + 1
            append(tokens[cursor], .type)
            cursor += 1
            while cursor + 1 < tokens.count, tokens[cursor].text == ".", tokens[cursor + 1].isWord {
                append(tokens[cursor + 1], .type)
                cursor += 2
            }
            if cursor < tokens.count, tokens[cursor].text == "(" {
                _ = recoverList(tokens, at: cursor, fields: true, append: append)
            }
        }
        guard tokens[0].upper == "CREATE", let start = tokens.firstIndex(where: { $0.text == "(" }) else { return }
        var depth = 0
        var tail = start
        repeat {
            if tokens[tail].text == "(" { depth += 1 }
            if tokens[tail].text == ")" { depth -= 1 }
            tail += 1
        } while tail < tokens.count && depth > 0
        guard depth == 0 else { return }
        // A grammar error in one type (for example Doris DATETIME(3)) must not
        // turn every following ordinary column definition into plain text.
        // Recover only a column-name + known-type pair at a definition boundary.
        var definitionStart = start + 1
        var columnDepth = 1
        for cursor in (start + 1)..<(tail - 1) {
            let token = tokens[cursor]
            if cursor == definitionStart, token.isWord, cursor + 1 < tail,
               tokens[cursor + 1].kind == nil, columnTypes.contains(tokens[cursor + 1].upper) {
                append(token, .property)
                append(tokens[cursor + 1], .builtinType)
                if cursor + 2 < tail,
                   (tokens[cursor + 1].upper == "DOUBLE" && tokens[cursor + 2].upper == "PRECISION")
                    || (tokens[cursor + 1].upper == "CHARACTER" && tokens[cursor + 2].upper == "VARYING") {
                    append(tokens[cursor + 2], .builtinType)
                }
            }
            if token.kind == nil, ["NULL", "TRUE", "FALSE"].contains(token.upper) { append(token, .boolean) }
            if token.text == "(" { columnDepth += 1 }
            if token.text == ")" { columnDepth -= 1 }
            if token.text == ",", columnDepth == 1 { definitionStart = cursor + 1 }
        }
        // Activate only on characteristic Doris CREATE TABLE clauses, never a free
        // keyword list that might recolor a column or string named "buckets".
        var index = tail
        while index < tokens.count {
            let word = tokens[index].upper
            if ["DUPLICATE", "AGGREGATE", "UNIQUE"].contains(word), index + 2 < tokens.count,
               tokens[index + 1].upper == "KEY", tokens[index + 2].text == "(" {
                append(tokens[index], .keyword); append(tokens[index + 1], .keyword)
                index = recoverList(tokens, at: index + 2, fields: true, append: append)
            } else if word == "DISTRIBUTED", index + 2 < tokens.count, tokens[index + 1].upper == "BY",
                      ["HASH", "RANDOM"].contains(tokens[index + 2].upper) {
                append(tokens[index], .keyword); append(tokens[index + 1], .keyword)
                append(tokens[index + 2], tokens[index + 2].upper == "HASH" ? .function : .keyword)
                index += 3
                if index < tokens.count, tokens[index].text == "(" {
                    index = recoverList(tokens, at: index, fields: true, append: append)
                }
                if index + 1 < tokens.count, tokens[index].upper == "BUCKETS",
                   tokens[index + 1].kind == .number || tokens[index + 1].upper == "AUTO" {
                    append(tokens[index], .keyword)
                    append(tokens[index + 1], tokens[index + 1].kind == .number ? .number : .keyword)
                    index += 2
                }
            } else if word == "PROPERTIES", index + 1 < tokens.count, tokens[index + 1].text == "(" {
                append(tokens[index], .keyword)
                index = recoverList(tokens, at: index + 1, fields: false, append: append)
            } else { index += 1 }
        }
    }

    private static func recoverList(_ tokens: [Token], at start: Int, fields: Bool,
                                    append: (Token, SQLSyntaxHighlight.Kind) -> Void) -> Int {
        var depth = 0
        var index = start
        repeat {
            let token = tokens[index]
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            if let kind = token.kind { append(token, kind) }
            else if token.isWord { append(token, fields ? .property : (token.isQuoted ? .string : .variable)) }
            else { append(token, ["(", ")", ",", "."].contains(token.text) ? .punctuation : .operator) }
            index += 1
        } while index < tokens.count && depth > 0
        return index
    }
}
