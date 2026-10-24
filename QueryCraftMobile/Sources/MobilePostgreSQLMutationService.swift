import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobilePostgreSQLMutationConnection: MobileMutationConnection {
    let client: LibPQClient
    func connect() async throws { try await client.connect() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        guard bindings.isEmpty else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
        let result = try await client.query(sql)
        return .init(columns: result.columns, columnTypes: result.columnTypes, rows: result.rows,
                     affectedRows: UInt64(max(0, result.affectedRows)))
    }
    func close() async { await client.close() }
}

/// Each submitted draft captures a physical target and its current metadata.
/// No database/schema/table identity is recovered by splitting a display label.
struct MobilePostgreSQLMutationService: MobileDataMutating {
    var object: MobileDatabaseObject?
    var columns: [MobileTableColumn] = []
    var makeConnection: @Sendable (MobileSQLConfiguration) -> any MobileMutationConnection = {
        MobilePostgreSQLMutationConnection(client: LibPQClient(configuration: $0.postgreSQL))
    }
    func scoped(to object: MobileDatabaseObject, columns: [MobileTableColumn]) -> any MobileDataMutating {
        var service = self; service.object = object; service.columns = columns; return service
    }
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MobileSQLConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws {
        guard !changes.isEmpty else { return }
        guard configuration.driver == .postgresql, let object, let schema = object.schemaName,
              object.kind == .table, changes.hasConsistentSelection, changes.selection == object.editingSelection,
              !columns.isEmpty else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
        let table = PostgreSQLDataMutation.TableIdentity(schema: schema, name: object.name)
        let client = makeConnection(configuration.selecting(database: object.database, schema: schema))
        let execute: @Sendable (String) async throws -> CDatabaseQueryResult = { sql in
            if sql != "ROLLBACK" {
                try Task.checkCancellation(); try await authorize(); try Task.checkCancellation()
            }
            do { return try await client.query(sql, bindings: []) }
            catch {
                // A server rejection (including a deferred constraint at COMMIT)
                // is definite. Lost/cancelled acknowledgement must never replay.
                if sql == "COMMIT", !Self.isDefiniteRejection(error) { throw MobileDataMutationError.uncertainCommit }
                throw error
            }
        }
        do {
            try await authorize(); try Task.checkCancellation(); try await client.connect()
            _ = try await execute("SET standard_conforming_strings TO on")
            _ = try await execute("SET statement_timeout TO '30s'")
            _ = try await execute("SET lock_timeout TO '5s'")
            try await PostgreSQLDataMutation.apply(changes, table: table, prepare: {
                // The transaction lock prevents DDL from replacing the validated
                // relation between metadata verification and the mutations.
                _ = try await execute("LOCK TABLE ONLY " + table.sql + " IN ROW EXCLUSIVE MODE")
                let relation = try await execute("SELECT c.relkind::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname="
                    + PostgreSQLCatalog.literal(schema) + " AND c.relname=" + PostgreSQLCatalog.literal(object.name))
                guard let kind = relation.rows.first?.first, kind == "r" || kind == "p" else {
                    throw WorkspaceDatabaseDataCellEditError.tableRequired
                }
                let fresh = try await execute(PostgreSQLCatalog.columnsQuery(schema: schema, name: object.name))
                let metadata = fresh.dictionaryRows.compactMap(PostgreSQLCatalog.column).map(MobileTableColumn.init)
                guard metadata == columns else { throw WorkspaceDatabaseDataCellEditError.editingContextChanged }
                let key = Set(columns.filter { $0.key == "PRI" }.map(\.name))
                for update in changes.rowUpdates {
                    guard !key.isEmpty, Set(update.primaryKey.map(\.columnName)) == key else {
                        throw WorkspaceDatabaseDataCellEditError.primaryKeyRequired
                    }
                }
                for delete in changes.deletes {
                    guard !key.isEmpty, Set(delete.conditions.map(\.columnName)) == key else {
                        throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
                    }
                }
            }, execute: { try await execute($0).affectedRows.intClamped })
            await client.close()
        } catch { await client.close(); throw error }
    }
    private static func isDefiniteRejection(_ error: any Error) -> Bool {
        guard let state = (error as? PostgreSQLClientError)?.sqlState else { return false }
        return !state.hasPrefix("08") && !["57P01", "57P02", "57P03"].contains(state)
    }
}
private extension UInt64 { var intClamped: Int { Int(clamping: self) } }
