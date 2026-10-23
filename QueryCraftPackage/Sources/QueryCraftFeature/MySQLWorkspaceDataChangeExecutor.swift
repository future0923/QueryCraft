/// Shared desktop/mobile transaction order, statement generation and row checks.
public enum MySQLWorkspaceDataChangeExecutor {
    public static func apply(_ changes: WorkspaceDatabaseDataChangeSet,
        execute: @Sendable (String, [WorkspaceDatabaseDataCell]) async throws -> UInt64) async throws {
        guard !changes.isEmpty else { return }
        guard changes.hasConsistentSelection else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
        _ = try await execute("START TRANSACTION", [])
        do {
            for delete in changes.deletes {
                try Task.checkCancellation()
                let statement = try MySQLWorkspaceDataRowDeleteStatement.make(delete: delete)
                let count = Int(clamping: try await execute(statement.sql, statement.bindings))
                guard count == 1 else {
                    if count == 0 { throw WorkspaceDatabaseDataRowDeleteError.rowChanged }
                    throw WorkspaceDatabaseDataRowDeleteError.unexpectedAffectedRows(count)
                }
            }
            for update in changes.rowUpdates {
                try Task.checkCancellation()
                let statement = try MySQLWorkspaceDataCellUpdateStatement.make(rowUpdate: update)
                let count = Int(clamping: try await execute(statement.sql, statement.bindings))
                guard count == 1 else {
                    if count == 0 { throw WorkspaceDatabaseDataCellEditError.rowChanged }
                    throw WorkspaceDatabaseDataCellEditError.unexpectedAffectedRows(count)
                }
            }
            for insert in changes.inserts {
                try Task.checkCancellation()
                let statement = try MySQLWorkspaceDataRowInsertStatement.make(insert: insert)
                let count = Int(clamping: try await execute(statement.sql, statement.bindings))
                guard count == 1 else { throw WorkspaceDatabaseDataRowInsertError.unexpectedAffectedRows(count) }
            }
            _ = try await execute("COMMIT", [])
        } catch {
            _ = try? await execute("ROLLBACK", [])
            throw error
        }
    }
}
