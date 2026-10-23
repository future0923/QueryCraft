import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

protocol MobileDataMutating: Sendable {
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MariaDBTransportConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws
}

enum MobileDataMutationError: LocalizedError {
    case pendingChanges
    case uncertainCommit
    case nonTransactionalTable
    var errorDescription: String? {
        switch self {
        case .pendingChanges: "当前连接还有待提交改动。请先回到表或查询结果提交或撤销，再刷新结果、更换或删除连接。"
        case .uncertainCommit: "提交结果无法确认。请刷新并核对服务器数据，确认前不要重复提交。"
        case .nonTransactionalTable: "此表不支持事务，无法保证批量修改失败时回滚。当前移动端仅支持 InnoDB 表的数据修改。"
        }
    }
}

/// A small connection boundary also permits fault tests to drop an actual
/// transaction's COMMIT acknowledgement without replaying any SQL.
protocol MobileMutationConnection: Sendable {
    func connect() async throws
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult
    func close() async
}

struct MobileMariaDBMutationConnection: MobileMutationConnection {
    let client: MariaDBClient
    func connect() async throws { try await client.connect() }
    func query(_ sql: String, bindings: [WorkspaceDatabaseDataCell]) async throws -> CDatabaseQueryResult {
        if bindings.isEmpty { return try await client.query(sql) }
        return try await client.query(sql, bindings: bindings)
    }
    func close() async { await client.close() }
}

struct MobileDataMutationService: MobileDataMutating {
    var makeConnection: @Sendable (MariaDBTransportConfiguration) -> any MobileMutationConnection = {
        MobileMariaDBMutationConnection(client: MariaDBClient(configuration: $0))
    }
    func apply(_ changes: WorkspaceDatabaseDataChangeSet, configuration: MariaDBTransportConfiguration,
               authorize: @escaping @Sendable () async throws -> Void) async throws {
        guard changes.hasConsistentSelection, let selection = changes.selection, selection.kind == .table else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        guard configuration.tlsMode == .disabled || configuration.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
        let client = makeConnection(.init(host: configuration.host, port: configuration.port,
            username: configuration.username, password: configuration.password, database: selection.databaseName, tlsMode: configuration.tlsMode))
        do {
            try await authorize(); try Task.checkCancellation()
            try await client.connect()
            // Fetch fresh engine/object identity before opening a transaction: views,
            // replaced tables and nontransactional engines must never bypass rollback.
            let info = try await client.query("SELECT TABLE_TYPE, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = "
                + MobileMySQLService.literal(selection.databaseName) + " AND TABLE_NAME = " + MobileMySQLService.literal(selection.objectName), bindings: [])
            guard let row = info.rows.first, row.count == 2, row[0] == "BASE TABLE" else {
                throw WorkspaceDatabaseDataCellEditError.tableRequired
            }
            guard row[1]?.uppercased() == "INNODB" else { throw MobileDataMutationError.nonTransactionalTable }
            try await authorize(); try Task.checkCancellation()
            try await MySQLWorkspaceDataChangeExecutor.apply(changes) { sql, bindings in
                // Cleanup must run even after the lock is re-enabled or the
                // foreground task is cancelled. Never gate rollback on UI state.
                if sql != "ROLLBACK" {
                    try Task.checkCancellation()
                    try await authorize()
                    try Task.checkCancellation()
                }
                do {
                    return try await client.query(sql, bindings: bindings).affectedRows
                }
                catch {
                    if sql == "COMMIT" { throw MobileDataMutationError.uncertainCommit }
                    throw error
                }
            }
            await client.close()
        } catch {
            await client.close() // Closing also rolls back if cancellation prevented explicit rollback.
            throw error
        }
    }
}
