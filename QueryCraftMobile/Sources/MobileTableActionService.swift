import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileTableActionInfo: Sendable {
    let nextAutoIncrement: String?
    let hasAutoIncrement: Bool
}
protocol MobileTableActionServicing: Sendable {
    func inspect(object: MobileDatabaseObject, configuration: MariaDBTransportConfiguration) async throws -> MobileTableActionInfo
    func perform(action: WorkspaceTableAction, object: MobileDatabaseObject, input: String,
                 configuration: MariaDBTransportConfiguration,
                 authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceTableActionStatement
}

enum MobileTableActionError: LocalizedError {
    case contextChanged, outcomeUnknown(String)
    var errorDescription: String? {
        switch self {
        case .contextChanged: "连接、数据库或操作上下文已变化，请重新打开表操作。"
        case .outcomeUnknown(let detail): "操作结果无法确认，请先核对服务器，勿重复执行。\n" + detail
        }
    }
}

struct MobileTableActionService: MobileTableActionServicing {
    var makeConnection: @Sendable (MariaDBTransportConfiguration) -> any MobileMutationConnection = {
        MobileMariaDBMutationConnection(client: MariaDBClient(configuration: $0))
    }
    private func client(_ config: MariaDBTransportConfiguration, object: MobileDatabaseObject) throws -> any MobileMutationConnection {
        guard object.kind == .table else { throw WorkspaceTableActionError.unsupported }
        guard config.tlsMode == .disabled || config.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
        return makeConnection(.init(host: config.host, port: config.port, username: config.username, password: config.password,
            database: object.database, tlsMode: config.tlsMode))
    }
    private func info(_ client: any MobileMutationConnection, object: MobileDatabaseObject) async throws -> MobileTableActionInfo {
        let predicate = "TABLE_SCHEMA = " + MobileMySQLService.literal(object.database)
            + " AND TABLE_NAME = " + MobileMySQLService.literal(object.name)
        let table = try await client.query("SELECT TABLE_TYPE, AUTO_INCREMENT FROM information_schema.TABLES WHERE " + predicate, bindings: [])
        guard let row = table.rows.first, row.count == 2, row[0] == "BASE TABLE" else { throw WorkspaceTableActionError.unsupported }
        let columns = try await client.query("SELECT EXTRA FROM information_schema.COLUMNS WHERE " + predicate, bindings: [])
        return .init(nextAutoIncrement: row[1], hasAutoIncrement: columns.rows.contains {
            ($0.first ?? nil)?.lowercased().contains("auto_increment") == true
        })
    }
    func inspect(object: MobileDatabaseObject, configuration: MariaDBTransportConfiguration) async throws -> MobileTableActionInfo {
        let client = try client(configuration, object: object)
        do {
            try Task.checkCancellation(); try await client.connect()
            let result = try await info(client, object: object)
            await client.close(); try Task.checkCancellation(); return result
        } catch { await client.close(); throw error }
    }
    func perform(action: WorkspaceTableAction, object: MobileDatabaseObject, input: String,
                 configuration: MariaDBTransportConfiguration,
                 authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceTableActionStatement {
        let statement = try WorkspaceTableActionStatement.make(action: action, selection: object.editingSelection, databaseType: .mysql, input: input)
        let client = try client(configuration, object: object)
        do {
            try Task.checkCancellation(); try await authorize(); try await client.connect()
            let metadata = try await info(client, object: object)
            if action == .resetAutoIncrement || action == .setAutoIncrement {
                guard metadata.hasAutoIncrement else { throw WorkspaceTableActionError.noAutoIncrement }
            }
            try Task.checkCancellation(); try await authorize(); try Task.checkCancellation()
            // MySQL DDL implicitly commits. Do not wrap these commands in the
            // row-edit transaction runner or claim cancellation can undo them.
            do { _ = try await client.query(statement.sql, bindings: []) }
            catch {
                if let failure = error as? CDatabaseClientError, !(2000..<3000).contains(failure.code), failure.sqlState?.hasPrefix("08") != true { throw error }
                throw MobileTableActionError.outcomeUnknown(error.localizedDescription)
            }
            await client.close()
            // Acknowledged success remains success if backgrounding or refresh
            // occurs afterwards. Never turn that into a retryable mutation.
            return statement
        } catch { await client.close(); throw error }
    }
}
