public struct MySQLWorkspaceDataCellUpdateStatement: Equatable, Sendable {
    public let sql: String
    public let bindings: [WorkspaceDatabaseDataCell]
    public let previewTokens: [WorkspaceSQLPreviewToken]

    public static func make(
        update: WorkspaceDatabaseDataCellUpdate
    ) throws -> Self {
        try make(rowUpdate: WorkspaceDatabaseDataRowUpdate(
            selection: update.selection,
            primaryKey: update.primaryKey,
            assignments: [update]
        ))
    }

    public static func make(
        rowUpdate: WorkspaceDatabaseDataRowUpdate
    ) throws -> Self {
        guard rowUpdate.selection.kind == .table else {
            throw WorkspaceDatabaseDataCellEditError.tableRequired
        }
        guard !rowUpdate.primaryKey.isEmpty else {
            throw WorkspaceDatabaseDataCellEditError.primaryKeyRequired
        }
        guard
            !rowUpdate.assignments.isEmpty,
            rowUpdate.assignments.allSatisfy({
                $0.selection == rowUpdate.selection
                    && $0.primaryKey == rowUpdate.primaryKey
            })
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        let predicate = rowUpdate.primaryKey.map {
            "\(quoteIdentifier($0.columnName)) = ?"
        }.joined(separator: " AND ")
        let qualifiedTable = "\(quoteIdentifier(rowUpdate.selection.databaseName))."
            + quoteIdentifier(rowUpdate.selection.objectName)
        let assignments: String = rowUpdate.assignments.map { update -> String in
            let value = update.assignment == .useDefault ? "DEFAULT" : "?"
            return "\(quoteIdentifier(update.columnName)) = \(value)"
        }.joined(separator: ", ")
        let assignmentBindings = rowUpdate.assignments.flatMap { update in
            update.assignment == .useDefault ? [] : [update.newValue]
        }
        let previewPrefix: [WorkspaceSQLPreviewToken] = [
            .init(text: "UPDATE", kind: .keyword),
            .init(text: " ", kind: .punctuation),
            .init(
                text: quoteIdentifier(rowUpdate.selection.databaseName),
                kind: .identifier
            ),
            .init(text: ".", kind: .punctuation),
            .init(
                text: quoteIdentifier(rowUpdate.selection.objectName),
                kind: .identifier
            ),
            .init(text: " ", kind: .punctuation),
            .init(text: "SET", kind: .keyword),
            .init(text: " ", kind: .punctuation),
        ]
        let assignmentTokens = rowUpdate.assignments.enumerated().flatMap {
            index, update -> [WorkspaceSQLPreviewToken] in
            let suffix = index == rowUpdate.assignments.count - 1
                ? ""
                : ", "
            let previewAssignment: WorkspaceSQLPreviewToken =
                update.assignment == .useDefault
                    ? .init(text: "DEFAULT", kind: .keyword)
                    : previewValueToken(update.newValue)
            return [
                .init(
                    text: quoteIdentifier(update.columnName),
                    kind: .identifier
                ),
                .init(text: " = ", kind: .punctuation),
                previewAssignment,
                .init(text: suffix, kind: .punctuation),
            ]
        }
        let previewWhere: [WorkspaceSQLPreviewToken] = [
            .init(text: " ", kind: .punctuation),
            .init(text: "WHERE", kind: .keyword),
            .init(text: " ", kind: .punctuation),
        ]
        let conditionTokens = rowUpdate.primaryKey.enumerated().flatMap {
            index, condition -> [WorkspaceSQLPreviewToken] in
            let prefix: [WorkspaceSQLPreviewToken] = index == 0
                ? []
                : [
                    .init(text: " ", kind: .punctuation),
                    .init(text: "AND", kind: .keyword),
                    .init(text: " ", kind: .punctuation),
                ]
            return prefix + [
                .init(
                    text: quoteIdentifier(condition.columnName),
                    kind: .identifier
                ),
                .init(text: " = ", kind: .punctuation),
                previewValueToken(condition.value),
            ]
        }
        return Self(
            sql: "UPDATE \(qualifiedTable) SET \(assignments) "
                + "WHERE \(predicate)",
            bindings: assignmentBindings
                + rowUpdate.primaryKey.map(\.value),
            previewTokens: previewPrefix + assignmentTokens + previewWhere
                + conditionTokens + [
                    .init(text: ";", kind: .punctuation),
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
