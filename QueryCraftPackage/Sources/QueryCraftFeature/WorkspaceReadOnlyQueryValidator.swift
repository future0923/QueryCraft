import Foundation

enum WorkspaceReadOnlyQueryValidator {
    static func validate(
        _ sql: String,
        policy: SQLExecutionPolicy = .readOnly
    ) throws -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspaceReadOnlyQueryValidationError.empty
        }

        let scan = scan(in: trimmed)
        let words = scan.tokens.compactMap(\.word)
        for index in words.indices.dropLast() where words[index] == "INTO" {
            if ["OUTFILE", "DUMPFILE"].contains(words[index + 1]) {
                throw WorkspaceReadOnlyQueryValidationError.serverFileWrite
            }
        }
        if scan.containsExecutableComment, !policy.allowsWrites {
            throw WorkspaceReadOnlyQueryValidationError
                .executableCommentRequiresWriteAccess
        }
        return sql
    }

    private struct ScanResult {
        var tokens: [Token] = []
        var containsExecutableComment = false
    }

    private static func scan(in sql: String) -> ScanResult {
        var result = ScanResult()
        var tokens: [Token] = []
        var index = sql.startIndex

        while index < sql.endIndex {
            let character = sql[index]
            if character.isWhitespace {
                index = sql.index(after: index)
                continue
            }
            if isMySQLDoubleHyphenComment(in: sql, at: index)
                || character == "#"
            {
                index = sql[index...].firstIndex(of: "\n") ?? sql.endIndex
                continue
            }
            if sql[index...].hasPrefix("/*") {
                guard let commentRange = sql[index...].range(of: "*/") else {
                    index = sql.endIndex
                    continue
                }
                if sql[index...].hasPrefix("/*!") {
                    result.containsExecutableComment = true
                    let payloadStart = sql.index(index, offsetBy: 3)
                    let payload = String(
                        sql[payloadStart..<commentRange.lowerBound]
                    )
                    let payloadScan = scan(in: payload)
                    tokens.append(contentsOf: payloadScan.tokens)
                    result.containsExecutableComment =
                        result.containsExecutableComment
                            || payloadScan.containsExecutableComment
                }
                index = commentRange.upperBound
                continue
            }
            if ["'", "\"", "`"].contains(character) {
                index = endOfQuotedValue(in: sql, from: index)
                continue
            }
            if character == ";" {
                index = sql.index(after: index)
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                repeat {
                    index = sql.index(after: index)
                } while index < sql.endIndex
                    && (sql[index].isLetter
                        || sql[index].isNumber
                        || sql[index] == "_")
                tokens.append(.word(String(sql[start..<index]).uppercased()))
                continue
            }
            index = sql.index(after: index)
        }
        result.tokens = tokens
        return result
    }

    private static func isMySQLDoubleHyphenComment(
        in sql: String,
        at index: String.Index
    ) -> Bool {
        guard sql[index...].hasPrefix("--") else { return false }
        let afterFirst = sql.index(after: index)
        let afterSecond = sql.index(after: afterFirst)
        guard afterSecond < sql.endIndex else { return false }
        let character = sql[afterSecond]
        if character.isWhitespace { return true }
        return character.unicodeScalars.allSatisfy { $0.value <= 0x20 }
    }

    private static func endOfQuotedValue(
        in sql: String,
        from start: String.Index
    ) -> String.Index {
        let quote = sql[start]
        var index = sql.index(after: start)
        while index < sql.endIndex {
            if sql[index] == "\\" {
                index = sql.index(after: index)
                if index < sql.endIndex {
                    index = sql.index(after: index)
                }
                continue
            }
            if sql[index] == quote {
                let next = sql.index(after: index)
                if next < sql.endIndex, sql[next] == quote {
                    index = sql.index(after: next)
                    continue
                }
                return next
            }
            index = sql.index(after: index)
        }
        return sql.endIndex
    }

    private enum Token {
        case word(String)

        var word: String? {
            if case let .word(value) = self { value } else { nil }
        }
    }
}

enum WorkspaceReadOnlyQueryValidationError: LocalizedError, Equatable {
    case empty
    case serverFileWrite
    case executableCommentRequiresWriteAccess

    var errorDescription: String? {
        switch self {
        case .empty:
            AppCopy.current.text("请输入要运行的 SQL 语句。", "Enter a SQL statement to run.")
        case .serverFileWrite:
            AppCopy.current.text(
                "QueryCraft 不允许执行 SELECT INTO OUTFILE 或 DUMPFILE。",
                "QueryCraft does not allow SELECT INTO OUTFILE or DUMPFILE."
            )
        case .executableCommentRequiresWriteAccess:
            AppCopy.current.text(
                "安全锁无法确定 MySQL 可执行注释的作用。停用安全锁后可提交原始 SQL。",
                "Safety Lock cannot determine what the MySQL executable comment does. Disable it to submit the exact SQL."
            )
        }
    }
}
