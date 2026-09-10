public struct MySQLWorkspaceDataRowInsertStatement: Equatable, Sendable {
    public let sql: String
    public let bindings: [WorkspaceDatabaseDataCell]
    public let previewTokens: [WorkspaceSQLPreviewToken]

    public var previewSQL: String {
        previewTokens.map(\.text).joined()
    }

    public static func make(
        insert: WorkspaceDatabaseDataRowInsert
    ) throws -> Self {
        guard insert.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowInsertError.tableRequired
        }
        let qualifiedTable = "\(quoteIdentifier(insert.selection.databaseName))."
            + quoteIdentifier(insert.selection.objectName)
        let previewPrefix = previewPrefix(insert.selection)
        guard !insert.values.isEmpty else {
            let sql = "INSERT INTO \(qualifiedTable) () VALUES ()"
            return Self(
                sql: sql,
                bindings: [],
                previewTokens: previewPrefix + [
                    .init(text: " ()\n", kind: .punctuation),
                    .init(text: "VALUES", kind: .keyword),
                    .init(text: " ();", kind: .punctuation),
                ]
            )
        }
        let columns = insert.values
            .map { quoteIdentifier($0.columnName) }
            .joined(separator: ", ")
        let placeholders = Array(
            repeating: "?",
            count: insert.values.count
        ).joined(separator: ", ")
        let prefix = "INSERT INTO \(qualifiedTable) (\(columns)) VALUES"
        return Self(
            sql: "\(prefix) (\(placeholders))",
            bindings: insert.values.map(\.value),
            previewTokens: previewPrefix
                + [.init(text: " (\n    ", kind: .punctuation)]
                + commaSeparatedLineTokens(
                    insert.values.map {
                        .init(
                            text: quoteIdentifier($0.columnName),
                            kind: .identifier
                        )
                    }
                )
                + [
                    .init(text: "\n)\n", kind: .punctuation),
                    .init(text: "VALUES", kind: .keyword),
                    .init(text: " (\n    ", kind: .punctuation),
                ]
                + commaSeparatedLineTokens(
                    insert.values.map { previewValueToken($0.value) }
                )
                + [.init(text: "\n);", kind: .punctuation)]
        )
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    private static func previewPrefix(
        _ selection: WorkspaceDatabaseObjectSelection
    ) -> [WorkspaceSQLPreviewToken] {
        [
            .init(text: "INSERT INTO", kind: .keyword),
            .init(text: " ", kind: .punctuation),
            .init(
                text: quoteIdentifier(selection.databaseName),
                kind: .identifier
            ),
            .init(text: ".", kind: .punctuation),
            .init(
                text: quoteIdentifier(selection.objectName),
                kind: .identifier
            ),
        ]
    }

    private static func commaSeparatedLineTokens(
        _ tokens: [WorkspaceSQLPreviewToken]
    ) -> [WorkspaceSQLPreviewToken] {
        tokens.enumerated().flatMap { index, token in
            index == 0
                ? [token]
                : [.init(text: ",\n    ", kind: .punctuation), token]
        }
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
