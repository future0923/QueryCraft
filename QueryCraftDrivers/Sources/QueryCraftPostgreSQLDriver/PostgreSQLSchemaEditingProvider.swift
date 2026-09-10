import Foundation
import QueryCraftFeature

struct PostgreSQLSchemaEditingProvider: DatabaseSchemaEditingProvider {
    static let dialectIdentifier = "postgresql"

    let capabilities: PostgreSQLCapabilities

    var descriptor: WorkspaceDatabaseSchemaEditingDescriptor {
        WorkspaceDatabaseSchemaEditingDescriptor(
            columnFields: [
                .name,
                .type,
                .primaryKey,
                .nullable,
                .defaultValue,
                .automaticValue,
                .generatedStorage,
                .generationExpression,
                .comment,
            ],
            indexFields: [.name, .kind, .columns, .method, .comment],
            defaultColumnType: "text",
            columnTypes: Self.columnTypes,
            indexKinds: [.primary, .unique, .normal],
            indexMethods: ["btree", "hash", "gist", "spgist", "gin", "brin"],
            generatedStorages: capabilities.hasGeneratedColumns
                ? [.none, .stored]
                : [.none],
            automaticValueStyle: capabilities.hasIdentityColumns
                ? .identity
                : nil,
            supportsTableOptions: false,
            supportsColumnVisibility: false,
            supportsOnUpdateExpression: false,
            supportsAlteringGeneratedColumns: false,
            supportsIndexPrefixLength: false,
            supportsIndexDirection: true
        )
    }

    func makeExecutionPlan(
        for changes: WorkspaceDatabaseSchemaChangeSet
    ) throws -> WorkspaceDatabaseSchemaExecutionPlan {
        WorkspaceDatabaseSchemaExecutionPlan(
            dialectIdentifier: Self.dialectIdentifier,
            source: .changes(changes),
            transactionMode: .transaction,
            statements: try PostgreSQLSchemaStatement.make(changes: changes)
        )
    }

    func makeExecutionPlan(
        for mutation: WorkspaceDatabaseTableMutation
    ) -> WorkspaceDatabaseSchemaExecutionPlan {
        WorkspaceDatabaseSchemaExecutionPlan(
            dialectIdentifier: Self.dialectIdentifier,
            source: .tableMutation(mutation),
            transactionMode: .transaction,
            statements: PostgreSQLSchemaStatement.make(mutation: mutation)
        )
    }

    private static let columnTypes = [
        "smallint", "integer", "bigint", "numeric", "numeric(10,2)",
        "real", "double precision", "smallserial", "serial", "bigserial",
        "money", "character(1)", "character varying(255)", "text", "bytea",
        "timestamp", "timestamp with time zone", "date", "time",
        "time with time zone", "interval", "boolean", "uuid", "json",
        "jsonb", "xml", "inet", "cidr", "macaddr", "bit", "bit varying",
        "tsvector", "tsquery", "point", "line", "lseg", "box", "path",
        "polygon", "circle",
    ]
}

private enum PostgreSQLSchemaStatement {
    typealias PlanStatement = WorkspaceDatabaseSchemaExecutionPlan.Statement
    typealias Token = WorkspaceSQLPreviewToken
    typealias Definition = WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    typealias IndexDefinition = WorkspaceDatabaseSchemaEditorState.IndexDefinition

    static func make(
        changes: WorkspaceDatabaseSchemaChangeSet
    ) throws -> [PlanStatement] {
        var statements: [PlanStatement] = []

        for item in changes.indexes where item.original != nil
            && (item.isDeleted || item.isModified) {
            guard let original = item.original else { continue }
            statements.append(dropIndex(original, from: changes.selection))
        }
        for item in changes.columns where item.isDeleted {
            guard let original = item.original else { continue }
            statements.append(
                alterTable(
                    changes.selection,
                    action: [keyword("DROP COLUMN"), space, identifier(original.name)]
                )
            )
        }
        for item in changes.columns where !item.isDeleted && item.isModified {
            statements.append(
                contentsOf: try alterColumn(item, in: changes.selection)
            )
        }
        for item in changes.indexes where !item.isDeleted && item.isModified {
            statements.append(addIndex(item.definition, to: changes.selection))
            if !item.definition.comment.isEmpty {
                statements.append(
                    commentOnIndex(
                        resolvedIndexName(
                            item.definition,
                            selection: changes.selection
                        ),
                        comment: item.definition.comment,
                        selection: changes.selection
                    )
                )
            }
        }
        return statements
    }

    static func make(
        mutation: WorkspaceDatabaseTableMutation
    ) -> [PlanStatement] {
        switch mutation {
        case let .create(databaseName, tableName, columns, indexes, _):
            let selection = WorkspaceDatabaseObjectSelection(
                databaseName: databaseName,
                objectName: tableName.contains(".")
                    ? tableName
                    : "public.\(tableName)",
                kind: .table
            )
            let definitions = columns.filter { !$0.isDeleted }.map {
                columnDefinition($0.definition)
            }
            var createTokens: [Token] = [
                keyword("CREATE TABLE"), space,
            ] + qualifiedTable(selection) + [punctuation(" (")]
                + commaSeparated(definitions) + [punctuation(")")]
            if definitions.isEmpty {
                createTokens = [keyword("CREATE TABLE"), space]
                    + qualifiedTable(selection) + [punctuation(" ()")]
            }
            var statements = [statement(createTokens, kind: .ddl(.create))]
            for item in columns where !item.isDeleted
                && !item.definition.comment.isEmpty {
                statements.append(
                    commentOnColumn(
                        item.definition.name,
                        comment: item.definition.comment,
                        selection: selection
                    )
                )
            }
            for item in indexes where !item.isDeleted {
                statements.append(addIndex(item.definition, to: selection))
                if !item.definition.comment.isEmpty {
                    statements.append(
                        commentOnIndex(
                            resolvedIndexName(
                                item.definition,
                                selection: selection
                            ),
                            comment: item.definition.comment,
                            selection: selection
                        )
                    )
                }
            }
            return statements

        case let .rename(selection, newName):
            return [
                statement(
                    [keyword("ALTER TABLE"), space] + qualifiedTable(selection)
                        + [space, keyword("RENAME TO"), space, identifier(newName)],
                    kind: .ddl(.alter)
                ),
            ]

        case let .drop(selection):
            return [
                statement(
                    [keyword("DROP TABLE"), space] + qualifiedTable(selection),
                    kind: .ddl(.drop)
                ),
            ]
        }
    }

    private static func alterColumn(
        _ item: WorkspaceDatabaseSchemaEditorState.ColumnItem,
        in selection: WorkspaceDatabaseObjectSelection
    ) throws -> [PlanStatement] {
        let definition = item.definition
        guard let original = item.original else {
            var result = [
                alterTable(
                    selection,
                    action: [keyword("ADD COLUMN"), space]
                        + columnDefinition(definition)
                ),
            ]
            if !definition.comment.isEmpty {
                result.append(
                    commentOnColumn(
                        definition.name,
                        comment: definition.comment,
                        selection: selection
                    )
                )
            }
            return result
        }

        var statements: [PlanStatement] = []
        let originalDefinition = Definition(column: original)
        let columnName = definition.name
        if original.name != columnName {
            statements.append(
                alterTable(
                    selection,
                    action: [
                        keyword("RENAME COLUMN"), space, identifier(original.name),
                        space, keyword("TO"), space, identifier(columnName),
                    ]
                )
            )
        }
        if originalDefinition.type != definition.type {
            statements.append(
                alterColumn(
                    columnName,
                    selection: selection,
                    clause: [keyword("TYPE"), space, typeExpression(definition.type)]
                )
            )
        }
        if originalDefinition.isNullable != definition.isNullable {
            statements.append(
                alterColumn(
                    columnName,
                    selection: selection,
                    clause: [
                        keyword(definition.isNullable ? "DROP NOT NULL" : "SET NOT NULL"),
                    ]
                )
            )
        }
        if originalDefinition.defaultMode != definition.defaultMode
            || originalDefinition.defaultValue != definition.defaultValue {
            let clause: [Token]
            switch definition.defaultMode {
            case .none:
                clause = [keyword("DROP DEFAULT")]
            case .null:
                clause = [keyword("SET DEFAULT"), space, nullLiteral]
            case .value:
                clause = [keyword("SET DEFAULT"), space, literal(definition.defaultValue)]
            case .expression:
                clause = [
                    keyword("SET DEFAULT"), space,
                    expression(definition.defaultValue),
                ]
            }
            statements.append(
                alterColumn(columnName, selection: selection, clause: clause)
            )
        }
        if originalDefinition.isAutoIncrement != definition.isAutoIncrement {
            let clause: [Token] = definition.isAutoIncrement
                ? [keyword("ADD GENERATED BY DEFAULT AS IDENTITY")]
                : [keyword("DROP IDENTITY")]
            statements.append(
                alterColumn(columnName, selection: selection, clause: clause)
            )
        }
        if originalDefinition.generatedStorage != definition.generatedStorage
            || originalDefinition.generationExpression
                != definition.generationExpression {
            guard definition.generatedStorage == .none else {
                throw PostgreSQLSchemaEditingError
                    .generatedColumnAlterationUnavailable
            }
            let clause: [Token]
            clause = [keyword("DROP EXPRESSION")]
            statements.append(
                alterColumn(columnName, selection: selection, clause: clause)
            )
        }
        if originalDefinition.comment != definition.comment {
            statements.append(
                commentOnColumn(
                    columnName,
                    comment: definition.comment,
                    selection: selection
                )
            )
        }
        return statements
    }

    private static func columnDefinition(_ definition: Definition) -> [Token] {
        var tokens = [identifier(definition.name), space, typeExpression(definition.type)]
        if definition.isGenerated {
            tokens += [
                space, keyword("GENERATED ALWAYS AS"), punctuation(" ("),
                expression(definition.generationExpression), punctuation(")"),
                space, keyword("STORED"),
            ]
        } else {
            if definition.isAutoIncrement {
                tokens += [space, keyword("GENERATED BY DEFAULT AS IDENTITY")]
            }
            switch definition.defaultMode {
            case .none:
                break
            case .null:
                tokens += [space, keyword("DEFAULT"), space, nullLiteral]
            case .value:
                tokens += [space, keyword("DEFAULT"), space, literal(definition.defaultValue)]
            case .expression:
                tokens += [
                    space, keyword("DEFAULT"), space,
                    expression(definition.defaultValue),
                ]
            }
        }
        if !definition.isNullable {
            tokens += [space, keyword("NOT NULL")]
        }
        return tokens
    }

    private static func alterColumn(
        _ name: String,
        selection: WorkspaceDatabaseObjectSelection,
        clause: [Token]
    ) -> PlanStatement {
        alterTable(
            selection,
            action: [keyword("ALTER COLUMN"), space, identifier(name), space]
                + clause
        )
    }

    private static func alterTable(
        _ selection: WorkspaceDatabaseObjectSelection,
        action: [Token]
    ) -> PlanStatement {
        statement(
            [keyword("ALTER TABLE"), space] + qualifiedTable(selection)
                + [space] + action,
            kind: .ddl(.alter)
        )
    }

    private static func addIndex(
        _ definition: IndexDefinition,
        to selection: WorkspaceDatabaseObjectSelection
    ) -> PlanStatement {
        let columns = commaSeparated(
            definition.columns.map(indexColumn)
        )
        if definition.kind == .primary {
            var action = [keyword("ADD")]
            let name = resolvedIndexName(definition, selection: selection)
            if !name.isEmpty {
                action += [
                    space, keyword("CONSTRAINT"), space,
                    identifier(name),
                ]
            }
            action += [space, keyword("PRIMARY KEY"), punctuation(" (")]
                + columns + [punctuation(")")]
            return alterTable(selection, action: action)
        }

        var tokens = [keyword("CREATE")]
        if definition.kind == .unique {
            tokens += [space, keyword("UNIQUE")]
        }
        tokens += [space, keyword("INDEX"), space, identifier(definition.name)]
            + [space, keyword("ON"), space] + qualifiedTable(selection)
        if !definition.method.isEmpty {
            tokens += [space, keyword("USING"), space, typeExpression(definition.method)]
        }
        tokens += [punctuation(" (")] + columns + [punctuation(")")]
        return statement(tokens, kind: .ddl(.create))
    }

    private static func dropIndex(
        _ index: WorkspaceDatabaseIndex,
        from selection: WorkspaceDatabaseObjectSelection
    ) -> PlanStatement {
        if index.isPrimary {
            return alterTable(
                selection,
                action: [
                    keyword("DROP CONSTRAINT"), space, identifier(index.name),
                ]
            )
        }
        let identity = tableIdentity(selection)
        return statement(
            [keyword("DROP INDEX"), space, identifier(identity.schema),
             punctuation("."), identifier(index.name)],
            kind: .ddl(.drop)
        )
    }

    private static func resolvedIndexName(
        _ definition: IndexDefinition,
        selection: WorkspaceDatabaseObjectSelection
    ) -> String {
        guard definition.kind == .primary,
              definition.name.isEmpty || definition.name == "PRIMARY"
        else {
            return definition.name
        }
        return "\(tableIdentity(selection).table)_pkey"
    }

    private static func indexColumn(
        _ column: WorkspaceDatabaseSchemaEditorState.IndexColumnDefinition
    ) -> [Token] {
        var tokens: [Token] = column.isExpression
            ? [expression(column.name)]
            : [identifier(column.name)]
        if column.isDescending {
            tokens += [space, keyword("DESC")]
        }
        return tokens
    }

    private static func commentOnColumn(
        _ column: String,
        comment: String,
        selection: WorkspaceDatabaseObjectSelection
    ) -> PlanStatement {
        let value = comment.isEmpty ? nullLiteral : literal(comment)
        return statement(
            [keyword("COMMENT ON COLUMN"), space] + qualifiedTable(selection)
                + [punctuation("."), identifier(column), space, keyword("IS"), space, value],
            kind: .ddl(.alter)
        )
    }

    private static func commentOnIndex(
        _ index: String,
        comment: String,
        selection: WorkspaceDatabaseObjectSelection
    ) -> PlanStatement {
        let identity = tableIdentity(selection)
        let value = comment.isEmpty ? nullLiteral : literal(comment)
        return statement(
            [keyword("COMMENT ON INDEX"), space, identifier(identity.schema),
             punctuation("."), identifier(index), space, keyword("IS"), space, value],
            kind: .ddl(.alter)
        )
    }

    private static func qualifiedTable(
        _ selection: WorkspaceDatabaseObjectSelection
    ) -> [Token] {
        let identity = tableIdentity(selection)
        return [
            identifier(identity.schema), punctuation("."), identifier(identity.table),
        ]
    }

    private static func tableIdentity(
        _ selection: WorkspaceDatabaseObjectSelection
    ) -> (schema: String, table: String) {
        guard let separator = selection.objectName.firstIndex(of: ".") else {
            return ("public", selection.objectName)
        }
        return (
            String(selection.objectName[..<separator]),
            String(selection.objectName[selection.objectName.index(after: separator)...])
        )
    }

    private static func statement(
        _ tokens: [Token],
        kind: SQLStatementKind
    ) -> PlanStatement {
        PlanStatement(
            sql: tokens.map(\.text).joined(),
            previewTokens: tokens + [punctuation(";")],
            kind: kind
        )
    }

    private static func commaSeparated(_ groups: [[Token]]) -> [Token] {
        groups.enumerated().flatMap { index, group in
            index == 0 ? group : [punctuation(", ")] + group
        }
    }

    private static var space: Token { punctuation(" ") }
    private static var nullLiteral: Token {
        .init(text: "NULL", kind: .nullLiteral)
    }
    private static func keyword(_ text: String) -> Token {
        .init(text: text, kind: .keyword)
    }
    private static func identifier(_ text: String) -> Token {
        .init(
            text: "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"",
            kind: .identifier
        )
    }
    private static func typeExpression(_ text: String) -> Token {
        .init(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: .keyword)
    }
    private static func expression(_ text: String) -> Token {
        .init(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: .expression)
    }
    private static func literal(_ text: String) -> Token {
        .init(
            text: "'\(text.replacingOccurrences(of: "'", with: "''"))'",
            kind: .stringLiteral
        )
    }
    private static func punctuation(_ text: String) -> Token {
        .init(text: text, kind: .punctuation)
    }
}

private enum PostgreSQLSchemaEditingError: LocalizedError {
    case generatedColumnAlterationUnavailable

    var errorDescription: String? {
        switch self {
        case .generatedColumnAlterationUnavailable:
            "PostgreSQL 17 cannot directly change the storage or expression of an existing generated column."
        }
    }
}
