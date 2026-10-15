import Foundation

/// The pinned SQL grammar does not understand MySQL/Doris ADD INDEX clauses.
/// Recover only their colors; never use this lexical recovery for execution or formatting.
enum SQLIndexHighlightRecovery {
    struct Correction: Sendable {
        let highlight: SQLSyntaxHighlight
        let preservesExistingSyntax: Bool
    }

    private typealias Token = SQLLexicalHighlightRecovery.Token

    private static let expressionTypes: Set<String> = [
        "BINARY", "CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "SIGNED", "UNSIGNED", "INTEGER", "INT",
        "BIGINT", "SMALLINT", "TINYINT", "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
        "DATE", "TIME", "DATETIME", "TIMESTAMP", "JSON", "JSONB", "BOOLEAN", "TEXT"
    ]
    private static let expressionKeywords: Set<String> = [
        "AS", "CASE", "WHEN", "THEN", "ELSE", "END", "AND", "OR", "NOT", "IS", "IN",
        "LIKE", "BETWEEN", "DISTINCT", "FROM", "INTERVAL", "DIV", "MOD", "COLLATE"
    ]

    static func highlights(in source: String) -> [Correction] {
        let isAlter = source.range(of: "ALTER", options: .caseInsensitive) != nil
            && source.range(of: "ADD", options: .caseInsensitive) != nil
        let isCreate = source.range(of: "CREATE", options: .caseInsensitive) != nil
            && source.range(of: "TABLE", options: .caseInsensitive) != nil
        guard isAlter || isCreate else { return [] }
        let tokens = SQLLexicalHighlightRecovery.tokens(in: source)
        var result: [Correction] = []
        var statement: [Token] = []
        for token in tokens {
            if token.text.hasPrefix("--") || token.text.hasPrefix("#") || token.text.hasPrefix("/*") {
                continue // Leave comment captures untouched, even between index columns.
            }
            if token.text == ";" {
                recover(statement, into: &result)
                statement.removeAll(keepingCapacity: true)
            } else {
                statement.append(token)
            }
        }
        recover(statement, into: &result)
        return result
    }

    private static func recover(_ tokens: [Token], into output: inout [Correction]) {
        guard tokens.count > 4, ["ALTER", "CREATE"].contains(tokens[0].upper), tokens[1].upper == "TABLE" else { return }
        let isCreate = tokens[0].upper == "CREATE"
        var preservesExistingSyntax = false
        func append(_ token: Token, _ kind: SQLSyntaxHighlight.Kind) {
            output.append(Correction(
                highlight: .init(range: SQLSourceRange(token.range), kind: kind),
                preservesExistingSyntax: preservesExistingSyntax
            ))
        }
        var index = 3
        var tableDepth = 0
        while index < tokens.count {
            if isCreate {
                if tokens[index].text == "(" { tableDepth += 1 }
                if tokens[index].text == ")" { tableDepth -= 1 }
                guard tableDepth == 1, ["INDEX", "KEY"].contains(tokens[index].upper) else { index += 1; continue }
                // Only table-level index clauses, not words in expressions/options.
                var lookahead = index + 1
                if lookahead < tokens.count, tokens[lookahead].isWord, tokens[lookahead].upper != "USING" { lookahead += 1 }
                if lookahead < tokens.count, tokens[lookahead].upper == "USING" { lookahead += 2 }
                guard lookahead < tokens.count, tokens[lookahead].text == "(" else { index += 1; continue }
            } else {
                guard tokens[index].upper == "ADD" else { index += 1; continue }
            }
            var cursor = isCreate ? index : index + 1
            if cursor < tokens.count, ["UNIQUE", "FULLTEXT", "SPATIAL"].contains(tokens[cursor].upper) {
                cursor += 1
            }
            guard cursor < tokens.count, ["INDEX", "KEY"].contains(tokens[cursor].upper) else {
                index += 1; continue
            }
            preservesExistingSyntax = false
            for token in tokens[index...cursor] { append(token, .keyword) }
            cursor += 1
            if cursor < tokens.count, tokens[cursor].isWord, tokens[cursor].upper != "USING" {
                append(tokens[cursor], .type) // index name is an object name
                cursor += 1
            }
            if cursor + 1 < tokens.count, tokens[cursor].upper == "USING" {
                append(tokens[cursor], .keyword)
                append(tokens[cursor + 1], .attribute)
                cursor += 2
            }
            guard cursor < tokens.count, tokens[cursor].text == "(" else { index = cursor; continue }
            var depth = 0
            repeat {
                let token = tokens[cursor]
                if token.text == "(" { depth += 1 }
                if token.text == ")" { depth -= 1 }
                // Only simple column names are certain. Inside expressions, the parser's
                // specialized captures (CAST, AS, CHAR, CASE, etc.) take precedence.
                preservesExistingSyntax = depth > 1
                if token.isWord {
                    let next = cursor + 1 < tokens.count ? tokens[cursor + 1] : nil
                    let isPrefixLength = next?.text == "(" && cursor + 2 < tokens.count
                        && tokens[cursor + 2].text.first?.isNumber == true && depth == 1
                    if !token.isQuoted && depth > 1 && cursor > 0
                        && tokens[cursor - 1].upper == "AS" && Self.expressionTypes.contains(token.upper) {
                        append(token, .builtinType)
                    } else if !token.isQuoted && depth > 1 && Self.expressionKeywords.contains(token.upper)
                        && !(token.upper == "MOD" && next?.text == "(") {
                        append(token, .keyword)
                    } else if token.isQuoted {
                        append(token, .property)
                    } else if ["ASC", "DESC", "NULLS", "FIRST", "LAST", "COLLATE"].contains(token.upper) {
                        append(token, .attribute)
                    } else if ["TRUE", "FALSE", "NULL"].contains(token.upper) {
                        append(token, .boolean)
                    } else {
                        append(token, next?.text == "(" && !isPrefixLength ? .function : .property)
                    }
                } else if token.kind == .string {
                    append(token, .string)
                } else if token.text.first?.isNumber == true {
                    append(token, .number)
                } else {
                    append(token, ["(", ")", ",", "."].contains(token.text) ? .punctuation : .operator)
                }
                cursor += 1
            } while cursor < tokens.count && depth > 0
            index = cursor
        }
    }
}
