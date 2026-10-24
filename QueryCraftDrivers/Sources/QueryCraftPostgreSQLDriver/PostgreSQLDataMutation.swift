import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

/// Shared PostgreSQL row SQL and atomic batch ordering for desktop and mobile.
enum PostgreSQLDataMutation {
    enum ValidationError: LocalizedError {
        case nullCharacter
        var errorDescription: String? { "PostgreSQL 文本不能包含 NUL 字符。" }
    }
    struct Statement: Sendable { let sql: String }
    struct TableIdentity: Sendable {
        let schema: String
        let name: String
        var sql: String { PostgreSQLCatalog.identifier(schema) + "." + PostgreSQLCatalog.identifier(name) }
    }
    static func updateStatement(
        _ update: WorkspaceDatabaseDataRowUpdate,
        table: TableIdentity) throws -> Statement {
        guard update.selection.kind == .table else {
            throw WorkspaceDatabaseDataCellEditError.tableRequired
        }
        guard !update.primaryKey.isEmpty else {
            throw WorkspaceDatabaseDataCellEditError.primaryKeyRequired
        }
        guard
            !update.assignments.isEmpty,
            update.assignments.allSatisfy({
                $0.selection == update.selection
                    && $0.primaryKey == update.primaryKey
            })
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }

        let assignments = try update.assignments.map { assignment in
            if assignment.assignment == .useDefault {
                return "\(PostgreSQLCatalog.identifier(assignment.columnName)) = DEFAULT"
            }
            let value = try sqlLiteral(assignment.newValue)
            return "\(PostgreSQLCatalog.identifier(assignment.columnName)) = \(value)"
        }
        let predicates = try update.primaryKey.map {
            "\(PostgreSQLCatalog.identifier($0.columnName)) = \(try sqlLiteral($0.value))"
        }
        return Statement(
            sql: "UPDATE \(table.sql) SET "
                + assignments.joined(separator: ", ")
                + " WHERE " + predicates.joined(separator: " AND ")
        )
    }

    static func insertStatement(
        _ insert: WorkspaceDatabaseDataRowInsert,
        table: TableIdentity) throws -> Statement {
        guard insert.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowInsertError.tableRequired
        }
        guard !insert.values.isEmpty else {
            return Statement(
                sql: "INSERT INTO \(table.sql) DEFAULT VALUES"
            )
        }
        let columns = insert.values.map { PostgreSQLCatalog.identifier($0.columnName) }
        let values = try insert.values.map { try sqlLiteral($0.value) }
        return Statement(
            sql: "INSERT INTO \(table.sql) ("
                + columns.joined(separator: ", ") + ") VALUES ("
                + values.joined(separator: ", ") + ")"
        )
    }

    static func deleteStatement(
        _ delete: WorkspaceDatabaseDataRowDelete,
        table: TableIdentity) throws -> Statement {
        guard delete.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        guard !delete.conditions.isEmpty else {
            throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
        }
        let predicates = try delete.conditions.map {
            "\(PostgreSQLCatalog.identifier($0.columnName)) = \(try sqlLiteral($0.value))"
        }
        return Statement(
            sql: "DELETE FROM \(table.sql) WHERE "
                + predicates.joined(separator: " AND ")
        )
    }

    static func sqlLiteral(
        _ cell: WorkspaceDatabaseDataCell
    ) throws -> String {
        switch cell {
        case .null:
            return "NULL"
        case .text(let value):
            // libpq accepts C strings; never let embedded NUL truncate a mutation.
            guard !value.utf8.contains(0) else { throw ValidationError.nullCharacter }
            return PostgreSQLCatalog.literal(value)
        case .binary:
            throw WorkspaceDatabaseDataCellEditError.binaryValueUnavailable
        }
    }


    static func preview(_ changes: WorkspaceDatabaseDataChangeSet, table: TableIdentity) throws -> String {
        try statements(changes, table: table).map { $0.sql + ";" }.joined(separator: "\n\n")
    }
    private static func statements(_ changes: WorkspaceDatabaseDataChangeSet, table: TableIdentity) throws -> [Statement] {
        guard changes.hasConsistentSelection else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
        return try changes.deletes.map { try deleteStatement($0, table: table) }
            + changes.rowUpdates.map { try updateStatement($0, table: table) }
            + changes.inserts.map { try insertStatement($0, table: table) }
    }
    static func apply(_ changes: WorkspaceDatabaseDataChangeSet, table: TableIdentity,
        prepare: @Sendable () async throws -> Void = {},
        execute: @Sendable (String) async throws -> Int) async throws {
        guard !changes.isEmpty else { return }
        let statements = try statements(changes, table: table)
        _ = try await execute("BEGIN")
        do {
            try await prepare()
            for (index, statement) in statements.enumerated() {
                try Task.checkCancellation()
                let count = try await execute(statement.sql)
                guard count == 1 else {
                    if index < changes.deletes.count {
                        if count == 0 { throw WorkspaceDatabaseDataRowDeleteError.rowChanged }
                        throw WorkspaceDatabaseDataRowDeleteError.unexpectedAffectedRows(count)
                    } else if index < changes.deletes.count + changes.rowUpdates.count {
                        if count == 0 { throw WorkspaceDatabaseDataCellEditError.rowChanged }
                        throw WorkspaceDatabaseDataCellEditError.unexpectedAffectedRows(count)
                    }
                    throw WorkspaceDatabaseDataRowInsertError.unexpectedAffectedRows(count)
                }
            }
            _ = try await execute("COMMIT")
        } catch { _ = try? await execute("ROLLBACK"); throw error }
    }
}
