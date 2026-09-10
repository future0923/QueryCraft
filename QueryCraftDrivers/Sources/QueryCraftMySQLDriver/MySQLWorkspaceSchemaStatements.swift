import Foundation
import QueryCraftFeature

struct MySQLWorkspaceSchemaStatement: Equatable, Sendable {
    let sql: String
    let previewTokens: [WorkspaceSQLPreviewToken]

    static func make(
        changes: WorkspaceDatabaseSchemaChangeSet
    ) -> [Self] {
        var statements: [Self] = []

        // Existing indexes must be removed before affected columns are altered.
        for item in changes.indexes where item.original != nil
            && (item.isDeleted || item.isModified) {
            guard let original = item.original else { continue }
            statements.append(dropIndex(original, from: changes.selection))
        }
        for item in changes.columns where item.isDeleted {
            guard let original = item.original else { continue }
            statements.append(dropColumn(original.name, from: changes.selection))
        }
        for item in changes.columns where !item.isDeleted && item.isModified {
            statements.append(
                alterColumn(item, in: changes.selection)
            )
        }
        for item in changes.indexes where !item.isDeleted && item.isModified {
            statements.append(
                addIndex(item.definition, to: changes.selection)
            )
        }
        if let optionsChange = changes.tableOptionsChange,
           let optionsStatement = alterTableOptions(
               optionsChange,
               in: changes.selection
           )
        {
            statements.append(optionsStatement)
        }
        return statements
    }

    static func make(
        tableMutation: WorkspaceDatabaseTableMutation
    ) -> Self {
        let sqlTokens: [WorkspaceSQLPreviewToken]
        let previewTokens: [WorkspaceSQLPreviewToken]
        switch tableMutation {
        case let .create(databaseName, tableName, columns, indexes, options):
            let columnGroups = columns
                .filter { !$0.isDeleted }
                .map { columnDefinitionTokens($0.definition) }
            let indexGroups = indexes
                .filter { !$0.isDeleted }
                .map { indexDefinitionTokens($0.definition, includesAdd: false) }
            let prefix: [WorkspaceSQLPreviewToken] = [
                keyword("CREATE TABLE"),
                space,
                identifier(databaseName),
                punctuation("."),
                identifier(tableName),
            ]
            let groups = columnGroups + indexGroups
            let optionGroups = tableOptionTokenGroups(options)
            sqlTokens = prefix + [punctuation(" (")]
                + commaSeparated(groups) + [punctuation(")")]
                + optionGroups.flatMap { [space] + $0 }
            previewTokens = prefix + [punctuation(" (\n")]
                + indentedCommaSeparated(groups) + [
                punctuation("\n)"),
            ] + optionGroups.flatMap { [punctuation("\n")] + $0 }

        case let .rename(selection, newName):
            let prefix: [WorkspaceSQLPreviewToken] = [
                keyword("RENAME TABLE"),
                space,
                identifier(selection.databaseName),
                punctuation("."),
                identifier(selection.objectName),
            ]
            let destination: [WorkspaceSQLPreviewToken] = [
                keyword("TO"),
                space,
                identifier(selection.databaseName),
                punctuation("."),
                identifier(newName),
            ]
            sqlTokens = prefix + [space] + destination
            previewTokens = prefix + [punctuation("\n    ")] + destination

        case let .drop(selection):
            sqlTokens = [
                keyword("DROP TABLE"),
                space,
                identifier(selection.databaseName),
                punctuation("."),
                identifier(selection.objectName),
            ]
            previewTokens = sqlTokens
        }
        return Self(
            sql: sqlTokens.map(\.text).joined(),
            previewTokens: previewTokens + [punctuation(";")]
        )
    }

    private static func tableOptionTokenGroups(
        _ options: WorkspaceDatabaseTableOptions
    ) -> [[WorkspaceSQLPreviewToken]] {
        var groups: [[WorkspaceSQLPreviewToken]] = []
        func appendIdentifierOption(_ keywordText: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            groups.append([
                keyword(keywordText),
                punctuation("="),
                unquotedIdentifier(value),
            ])
        }
        func appendNumericOption(_ keywordText: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            groups.append([
                keyword(keywordText),
                punctuation("="),
                .init(text: value, kind: .numericLiteral),
            ])
        }

        appendIdentifierOption("ENGINE", options.engine)
        appendIdentifierOption("DEFAULT CHARACTER SET", options.characterSet)
        appendIdentifierOption("COLLATE", options.collation)
        appendIdentifierOption("ROW_FORMAT", options.rowFormat)
        appendNumericOption("AUTO_INCREMENT", options.autoIncrement)
        if !options.comment.isEmpty {
            groups.append([
                keyword("COMMENT"),
                punctuation("="),
                .init(
                    text: "'\(escapeLiteral(options.comment))'",
                    kind: .stringLiteral
                ),
            ])
        }
        appendNumericOption("AVG_ROW_LENGTH", options.averageRowLength)
        appendNumericOption("MIN_ROWS", options.minimumRows)
        appendNumericOption("MAX_ROWS", options.maximumRows)
        appendNumericOption("KEY_BLOCK_SIZE", options.keyBlockSize)
        return groups
    }

    private static func alterTableOptions(
        _ change: WorkspaceDatabaseTableOptionsChange,
        in selection: WorkspaceDatabaseObjectSelection
    ) -> Self? {
        let original = change.original
        let updated = change.updated
        var groups: [[WorkspaceSQLPreviewToken]] = []

        func appendIdentifier(
            _ keywordText: String,
            original originalValue: String,
            updated updatedValue: String,
            emptyValue: String? = nil
        ) {
            guard originalValue != updatedValue else { return }
            let trimmed = updatedValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty || emptyValue != nil else { return }
            groups.append([
                keyword(keywordText),
                punctuation("="),
                unquotedIdentifier(trimmed.isEmpty ? emptyValue! : trimmed),
            ])
        }

        func appendNumeric(
            _ keywordText: String,
            original originalValue: String,
            updated updatedValue: String,
            emptyValue: String
        ) {
            guard originalValue != updatedValue else { return }
            let trimmed = updatedValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            groups.append([
                keyword(keywordText),
                punctuation("="),
                .init(
                    text: trimmed.isEmpty ? emptyValue : trimmed,
                    kind: .numericLiteral
                ),
            ])
        }

        appendIdentifier(
            "ENGINE",
            original: original.engine,
            updated: updated.engine
        )
        appendIdentifier(
            "DEFAULT CHARACTER SET",
            original: original.characterSet,
            updated: updated.characterSet
        )
        appendIdentifier(
            "COLLATE",
            original: original.collation,
            updated: updated.collation
        )
        appendIdentifier(
            "ROW_FORMAT",
            original: original.rowFormat,
            updated: updated.rowFormat,
            emptyValue: "DEFAULT"
        )
        appendNumeric(
            "AUTO_INCREMENT",
            original: original.autoIncrement,
            updated: updated.autoIncrement,
            emptyValue: "1"
        )
        if original.comment != updated.comment {
            groups.append([
                keyword("COMMENT"),
                punctuation("="),
                .init(
                    text: "'\(escapeLiteral(updated.comment))'",
                    kind: .stringLiteral
                ),
            ])
        }
        appendNumeric(
            "AVG_ROW_LENGTH",
            original: original.averageRowLength,
            updated: updated.averageRowLength,
            emptyValue: "0"
        )
        appendNumeric(
            "MIN_ROWS",
            original: original.minimumRows,
            updated: updated.minimumRows,
            emptyValue: "0"
        )
        appendNumeric(
            "MAX_ROWS",
            original: original.maximumRows,
            updated: updated.maximumRows,
            emptyValue: "0"
        )
        appendNumeric(
            "KEY_BLOCK_SIZE",
            original: original.keyBlockSize,
            updated: updated.keyBlockSize,
            emptyValue: "0"
        )

        guard !groups.isEmpty else { return nil }
        let prefix: [WorkspaceSQLPreviewToken] = [
            keyword("ALTER TABLE"),
            space,
            identifier(selection.databaseName),
            punctuation("."),
            identifier(selection.objectName),
        ]
        return Self(
            sql: (prefix + [space] + commaSeparated(groups))
                .map(\.text).joined(),
            previewTokens: prefix
                + groups.enumerated().flatMap { index, group in
                    [punctuation(index == 0 ? "\n    " : ",\n    ")] + group
                }
                + [punctuation(";")]
        )
    }

    private static func alterColumn(
        _ item: WorkspaceDatabaseSchemaEditorState.ColumnItem,
        in selection: WorkspaceDatabaseObjectSelection
    ) -> Self {
        let definition = columnDefinitionTokens(item.definition)
        var action: [WorkspaceSQLPreviewToken]
        if let original = item.original {
            if original.name == item.definition.name {
                action = [keyword("MODIFY COLUMN"), space]
            } else {
                action = [
                    keyword("CHANGE COLUMN"),
                    space,
                    identifier(original.name),
                    space,
                ]
            }
        } else {
            action = [keyword("ADD COLUMN"), space]
        }
        action.append(contentsOf: definition)
        return statement(selection: selection, actionTokens: action)
    }

    private static func dropColumn(
        _ name: String,
        from selection: WorkspaceDatabaseObjectSelection
    ) -> Self {
        statement(selection: selection, actionTokens: [
            keyword("DROP COLUMN"),
            space,
            identifier(name),
        ])
    }

    private static func columnDefinitionTokens(
        _ definition: WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> [WorkspaceSQLPreviewToken] {
        let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = definition.type.trimmingCharacters(in: .whitespacesAndNewlines)

        var tokens = [identifier(name), space, keyword(type)]
        func appendClause(_ clause: [WorkspaceSQLPreviewToken]) {
            tokens.append(space)
            tokens.append(contentsOf: clause)
        }
        if definition.supportsCharacterSetAndCollation,
           !definition.characterSet.isEmpty
        {
            appendClause([
                keyword("CHARACTER SET"),
                space,
                unquotedIdentifier(definition.characterSet),
            ])
        }
        if definition.supportsCharacterSetAndCollation,
           !definition.collation.isEmpty
        {
            appendClause([
                keyword("COLLATE"),
                space,
                unquotedIdentifier(definition.collation),
            ])
        }
        if definition.isGenerated {
            let expression = definition.generationExpression
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendClause([
                keyword("GENERATED ALWAYS AS"),
                punctuation(" ("),
                .init(text: expression, kind: .expression),
                punctuation(")"),
            ])
            appendClause([
                keyword(definition.generatedStorage.rawValue.uppercased()),
            ])
        } else {
            if !definition.isNullable {
                appendClause([keyword("NOT NULL")])
            }
            switch definition.defaultMode {
            case .none:
                break
            case .null:
                appendClause([
                    keyword("DEFAULT"),
                    space,
                    .init(text: "NULL", kind: .nullLiteral),
                ])
            case .value:
                appendClause([
                    keyword("DEFAULT"),
                    space,
                    defaultLiteralToken(definition.defaultValue, type: type),
                ])
            case .expression:
                let expression = definition.defaultValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                appendClause([
                    keyword("DEFAULT"),
                    space,
                    .init(text: expression, kind: .expression),
                ])
            }
            let onUpdateExpression = definition.onUpdateExpression
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !onUpdateExpression.isEmpty {
                appendClause([
                    keyword("ON UPDATE"),
                    space,
                    .init(text: onUpdateExpression, kind: .expression),
                ])
            }
            if definition.isAutoIncrement {
                appendClause([keyword("AUTO_INCREMENT")])
            }
        }
        if !definition.isVisible {
            appendClause([keyword("INVISIBLE")])
        }
        if !definition.comment.isEmpty {
            appendClause([
                keyword("COMMENT"),
                space,
                .init(
                    text: "'\(escapeLiteral(definition.comment))'",
                    kind: .stringLiteral
                ),
            ])
        }
        return tokens
    }

    private static func addIndex(
        _ definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition,
        to selection: WorkspaceDatabaseObjectSelection
    ) -> Self {
        statement(
            selection: selection,
            actionTokens: indexDefinitionTokens(definition, includesAdd: true)
        )
    }

    private static func indexDefinitionTokens(
        _ definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition,
        includesAdd: Bool
    ) -> [WorkspaceSQLPreviewToken] {
        let columns = definition.columns.map { column -> [WorkspaceSQLPreviewToken] in
            let name = column.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var result = [identifier(name)]
            let prefix = column.prefixLength.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                result.append(punctuation("("))
                result.append(.init(text: prefix, kind: .numericLiteral))
                result.append(punctuation(")"))
            }
            if column.isDescending {
                result.append(space)
                result.append(keyword("DESC"))
            }
            return result
        }

        var action: [WorkspaceSQLPreviewToken]
        switch definition.kind {
        case .primary:
            action = [keyword(includesAdd ? "ADD PRIMARY KEY" : "PRIMARY KEY")]
        case .unique:
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            action = [
                keyword(includesAdd ? "ADD UNIQUE INDEX" : "UNIQUE INDEX"),
                space,
                identifier(name),
            ]
        case .normal:
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            action = [
                keyword(includesAdd ? "ADD INDEX" : "INDEX"),
                space,
                identifier(name),
            ]
        case .fulltext:
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            action = [
                keyword(includesAdd ? "ADD FULLTEXT INDEX" : "FULLTEXT INDEX"),
                space,
                identifier(name),
            ]
        case .spatial:
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            action = [
                keyword(includesAdd ? "ADD SPATIAL INDEX" : "SPATIAL INDEX"),
                space,
                identifier(name),
            ]
        }
        action.append(punctuation(" ("))
        action.append(contentsOf: commaSeparated(columns))
        action.append(punctuation(")"))
        if !definition.method.isEmpty,
            definition.kind != .fulltext,
            definition.kind != .spatial {
            action.append(contentsOf: [
                space,
                keyword("USING"),
                space,
                keyword(definition.method.uppercased()),
            ])
        }
        if !definition.comment.isEmpty {
            action.append(contentsOf: [
                space,
                keyword("COMMENT"),
                space,
                .init(
                    text: "'\(escapeLiteral(definition.comment))'",
                    kind: .stringLiteral
                ),
            ])
        }
        if !definition.isVisible {
            action.append(contentsOf: [space, keyword("INVISIBLE")])
        }
        return action
    }

    private static func dropIndex(
        _ index: WorkspaceDatabaseIndex,
        from selection: WorkspaceDatabaseObjectSelection
    ) -> Self {
        let action: [WorkspaceSQLPreviewToken] = index.name == "PRIMARY"
            ? [keyword("DROP PRIMARY KEY")]
            : [keyword("DROP INDEX"), space, identifier(index.name)]
        return statement(selection: selection, actionTokens: action)
    }

    private static func statement(
        selection: WorkspaceDatabaseObjectSelection,
        actionTokens: [WorkspaceSQLPreviewToken]
    ) -> Self {
        let sqlTokens: [WorkspaceSQLPreviewToken] = [
            keyword("ALTER TABLE"),
            space,
            identifier(selection.databaseName),
            punctuation("."),
            identifier(selection.objectName),
            space,
        ] + actionTokens
        let previewTokens: [WorkspaceSQLPreviewToken] = [
            keyword("ALTER TABLE"),
            space,
            identifier(selection.databaseName),
            punctuation("."),
            identifier(selection.objectName),
            punctuation("\n    "),
        ] + actionTokens
        return Self(
            sql: sqlTokens.map(\.text).joined(),
            previewTokens: previewTokens + [punctuation(";")]
        )
    }

    private static var space: WorkspaceSQLPreviewToken {
        punctuation(" ")
    }

    private static func keyword(_ text: String) -> WorkspaceSQLPreviewToken {
        .init(text: text, kind: .keyword)
    }

    private static func identifier(_ text: String) -> WorkspaceSQLPreviewToken {
        .init(text: quote(text), kind: .identifier)
    }

    private static func unquotedIdentifier(
        _ text: String
    ) -> WorkspaceSQLPreviewToken {
        .init(text: text, kind: .identifier)
    }

    private static func punctuation(_ text: String) -> WorkspaceSQLPreviewToken {
        .init(text: text, kind: .punctuation)
    }

    private static func commaSeparated(
        _ groups: [[WorkspaceSQLPreviewToken]]
    ) -> [WorkspaceSQLPreviewToken] {
        groups.enumerated().flatMap { index, group in
            index == 0 ? group : [punctuation(", ")] + group
        }
    }

    private static func indentedCommaSeparated(
        _ groups: [[WorkspaceSQLPreviewToken]]
    ) -> [WorkspaceSQLPreviewToken] {
        groups.enumerated().flatMap { index, group in
            let prefix = index == 0 ? "    " : ",\n    "
            return [punctuation(prefix)] + group
        }
    }

    private static func quote(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    private static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    private static func defaultLiteralToken(
        _ value: String,
        type: String
    ) -> WorkspaceSQLPreviewToken {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let numericTypes = [
            "TINYINT", "SMALLINT", "MEDIUMINT", "INT", "INTEGER", "BIGINT",
            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL", "BIT", "YEAR",
        ]
        if Double(trimmed) != nil,
            numericTypes.contains(where: { type.uppercased().hasPrefix($0) }) {
            return .init(text: trimmed, kind: .numericLiteral)
        }
        return .init(
            text: "'\(escapeLiteral(trimmed))'",
            kind: .stringLiteral
        )
    }
}
