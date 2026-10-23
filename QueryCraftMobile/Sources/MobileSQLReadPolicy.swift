import Foundation

/// Conservative single-statement MySQL read policy. The server also executes
/// requests in READ ONLY transactions; this is not a replacement for DB grants.
enum MobileSQLReadPolicy {
    static func validate(_ sql: String, backslashEscapes: Bool = true) throws {
        guard !sql.isEmpty, sql.utf8.count <= 262_144 else { throw MobileQueryError.readOnlySQLRequired }
        let chars = Array(sql)
        var i = 0, tokens: [String] = [], ended = false
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "#" || (ch == "-" && i + 2 < chars.count && chars[i + 1] == "-" && chars[i + 2].isWhitespace) {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if ch == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                guard i + 2 < chars.count, chars[i + 2] != "!",
                      !(chars[i + 2] == "M" && i + 3 < chars.count && chars[i + 3] == "!") else {
                    throw MobileQueryError.readOnlySQLRequired
                }
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                guard i + 1 < chars.count else { throw MobileQueryError.readOnlySQLRequired }
                i += 2; continue
            }
            guard !ended else { throw MobileQueryError.readOnlySQLRequired }
            if ch == ";" { ended = true; i += 1; continue }
            if ["'", "\"", "`"].contains(ch) {
                let quote = ch
                var closed = false
                i += 1
                while i < chars.count {
                    if chars[i] == "\\", quote != "`", backslashEscapes { i += 2; continue }
                    if chars[i] == quote {
                        if i + 1 < chars.count, chars[i + 1] == quote { i += 2; continue }
                        i += 1; closed = true; break
                    }
                    i += 1
                }
                guard closed else { throw MobileQueryError.readOnlySQLRequired }
                continue
            }
            if ch.isLetter || ch == "_" {
                let start = i
                repeat { i += 1 } while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_")
                tokens.append(String(chars[start..<i]).uppercased())
            } else { i += 1 }
        }
        guard let first = tokens.first, ["SELECT", "WITH", "SHOW", "DESCRIBE", "DESC", "EXPLAIN"].contains(first) else {
            throw MobileQueryError.readOnlySQLRequired
        }
        guard !tokens.contains("OUTFILE"), !tokens.contains("DUMPFILE") else { throw MobileQueryError.readOnlySQLRequired }
        if first != "SHOW", first != "DESCRIBE", first != "DESC" {
            let forbidden: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT", "REVOKE", "CALL", "SET", "USE", "LOAD", "LOCK", "UNLOCK", "INTO", "INSTALL", "UNINSTALL"]
            guard tokens.allSatisfy({ !forbidden.contains($0) }) else { throw MobileQueryError.readOnlySQLRequired }
        }
    }
}
