public struct MySQLWorkspaceDataRowDeleteStatement: Equatable, Sendable {
    public let sql: String
    public let bindings: [WorkspaceDatabaseDataCell]
    public let previewTokens: [WorkspaceSQLPreviewToken]

    public static func make(
        delete: WorkspaceDatabaseDataRowDelete
    ) throws -> Self {
        guard delete.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        guard !delete.conditions.isEmpty else {
            throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
        }
        let qualifiedTable = "\(quoteIdentifier(delete.selection.databaseName))."
            + quoteIdentifier(delete.selection.objectName)
        let predicate = delete.conditions.map {
            "\(quoteIdentifier($0.columnName)) = ?"
        }.joined(separator: " AND ")
        let previewPrefix: [WorkspaceSQLPreviewToken] = [
            .init(text: "DELETE FROM", kind: .keyword),
            .init(text: " ", kind: .punctuation),
            .init(
                text: quoteIdentifier(delete.selection.databaseName),
                kind: .identifier
            ),
            .init(text: ".", kind: .punctuation),
            .init(
                text: quoteIdentifier(delete.selection.objectName),
                kind: .identifier
            ),
            .init(text: "\n", kind: .punctuation),
            .init(text: "WHERE", kind: .keyword),
            .init(text: " ", kind: .punctuation),
        ]
        let conditionTokens = delete.conditions.enumerated().flatMap {
            index, condition -> [WorkspaceSQLPreviewToken] in
            let prefix: [WorkspaceSQLPreviewToken] = index == 0
                ? []
                : [
                    .init(text: "\n    ", kind: .punctuation),
                    .init(text: "AND", kind: .keyword),
                    .init(text: " ", kind: .punctuation),
                ]
            return prefix + [
                .init(text: quoteIdentifier(condition.columnName), kind: .identifier),
                .init(text: " = ", kind: .punctuation),
                previewValueToken(condition.value),
            ]
        }
        return Self(
            sql: "DELETE FROM \(qualifiedTable) WHERE \(predicate) LIMIT 1",
            bindings: delete.conditions.map(\.value),
            previewTokens: previewPrefix + conditionTokens + [
                .init(text: "\n", kind: .punctuation),
                .init(text: "LIMIT", kind: .keyword),
                .init(text: " 1;", kind: .punctuation),
            ]
        )
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    private static func previewValueToken(
        _ value: WorkspaceDatabaseDataCell
    ) -> WorkspaceSQLPreviewToken {
        switch value {
        case .null:
            .init(text: "NULL", kind: .nullLiteral)
        case let .text(text):
            .init(
                text: "'\(escapePreviewText(text))'",
                kind: .stringLiteral
            )
        case .binary:
            .init(text: "?", kind: .punctuation)
        }
    }

    private static func escapePreviewText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{001A}", with: "\\Z")
    }
}
