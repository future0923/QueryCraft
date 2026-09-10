enum PostgreSQLWorkspaceDataPreviewStatement {
    static func make(
        rowUpdate: WorkspaceDatabaseDataRowUpdate
    ) throws -> WorkspaceSQLPreviewStatement {
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

        var tokens = prefix(
            keyword: "UPDATE",
            selection: rowUpdate.selection,
            suffix: "\n"
        )
        tokens += [keyword("SET"), punctuation(" ")]
        tokens += separated(rowUpdate.assignments.map { update in
            [
                identifierToken(update.columnName),
                punctuation(" = "),
                update.assignment == .useDefault
                    ? keyword("DEFAULT")
                    : valueToken(update.newValue),
            ]
        }, separator: ",\n    ")
        tokens += [punctuation("\n"), keyword("WHERE"), punctuation(" ")]

        let primaryKeyConditions = rowUpdate.primaryKey.map {
            conditionTokens(column: $0.columnName, value: $0.value)
        }
        tokens += separated(
            primaryKeyConditions,
            separator: "\n  AND "
        )
        tokens.append(punctuation(";"))
        return WorkspaceSQLPreviewStatement(tokens: tokens)
    }

    static func make(
        rowInsert: WorkspaceDatabaseDataRowInsert
    ) throws -> WorkspaceSQLPreviewStatement {
        guard rowInsert.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowInsertError.tableRequired
        }
        var tokens = prefix(
            keyword: "INSERT INTO",
            selection: rowInsert.selection,
            suffix: ""
        )
        guard !rowInsert.values.isEmpty else {
            tokens += [
                punctuation("\n"), keyword("DEFAULT VALUES"), punctuation(";"),
            ]
            return WorkspaceSQLPreviewStatement(tokens: tokens)
        }
        tokens.append(punctuation(" (\n    "))
        tokens += separated(
            rowInsert.values.map { [identifierToken($0.columnName)] },
            separator: ",\n    "
        )
        tokens += [punctuation("\n)\n"), keyword("VALUES"), punctuation(" (\n    ")]
        tokens += separated(
            rowInsert.values.map { [valueToken($0.value)] },
            separator: ",\n    "
        )
        tokens.append(punctuation("\n);"))
        return WorkspaceSQLPreviewStatement(tokens: tokens)
    }

    static func make(
        rowDelete: WorkspaceDatabaseDataRowDelete
    ) throws -> WorkspaceSQLPreviewStatement {
        guard rowDelete.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        guard !rowDelete.conditions.isEmpty else {
            throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
        }
        var tokens = prefix(
            keyword: "DELETE FROM",
            selection: rowDelete.selection,
            suffix: "\n"
        )
        tokens += [keyword("WHERE"), punctuation(" ")]
        tokens += separated(
            rowDelete.conditions.map {
                conditionTokens(column: $0.columnName, value: $0.value)
            },
            separator: "\n  AND "
        )
        tokens.append(punctuation(";"))
        return WorkspaceSQLPreviewStatement(tokens: tokens)
    }

    private static func prefix(
        keyword keywordText: String,
        selection: WorkspaceDatabaseObjectSelection,
        suffix: String
    ) -> [WorkspaceSQLPreviewToken] {
        let name = splitObjectName(selection.objectName)
        return [
            keyword(keywordText),
            punctuation(" "),
            identifierToken(name.schema),
            punctuation("."),
            identifierToken(name.name),
            punctuation(suffix),
        ]
    }

    private static func conditionTokens(
        column: String,
        value: WorkspaceDatabaseDataCell
    ) -> [WorkspaceSQLPreviewToken] {
        [
            identifierToken(column),
            punctuation(" = "),
            valueToken(value),
        ]
    }

    private static func splitObjectName(
        _ value: String
    ) -> (schema: String, name: String) {
        guard let separator = value.firstIndex(of: ".") else {
            return ("public", value)
        }
        return (
            String(value[..<separator]),
            String(value[value.index(after: separator)...])
        )
    }

    private static func separated(
        _ groups: [[WorkspaceSQLPreviewToken]],
        separator: String
    ) -> [WorkspaceSQLPreviewToken] {
        groups.enumerated().flatMap { index, group in
            index == 0 ? group : [punctuation(separator)] + group
        }
    }

    private static func valueToken(
        _ value: WorkspaceDatabaseDataCell
    ) -> WorkspaceSQLPreviewToken {
        switch value {
        case .null:
            return .init(text: "NULL", kind: .nullLiteral)
        case .text(let value):
            return .init(
                text: "'\(value.replacingOccurrences(of: "'", with: "''"))'",
                kind: .stringLiteral
            )
        case .binary:
            return punctuation("?")
        }
    }

    private static func identifierToken(
        _ value: String
    ) -> WorkspaceSQLPreviewToken {
        .init(
            text: "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"",
            kind: .identifier
        )
    }

    private static func keyword(_ value: String) -> WorkspaceSQLPreviewToken {
        .init(text: value, kind: .keyword)
    }

    private static func punctuation(_ value: String) -> WorkspaceSQLPreviewToken {
        .init(text: value, kind: .punctuation)
    }
}
