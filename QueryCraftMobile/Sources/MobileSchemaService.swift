import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileSchemaSnapshot: Equatable, Sendable {
    let columns: [WorkspaceDatabaseColumn]
    let indexes: [WorkspaceDatabaseIndex]
    let choices: WorkspaceDatabaseSchemaChoices
    let ddl: String
    var options: WorkspaceDatabaseTableOptions? = nil
    func matchesStructure(_ other: Self) -> Bool {
        columns == other.columns && indexes.count == other.indexes.count && zip(indexes, other.indexes).allSatisfy {
            WorkspaceDatabaseSchemaEditorState.IndexDefinition(index: $0).matches($1)
        }
    }
}
protocol MobileSchemaServicing: Sendable {
    func load(object: MobileDatabaseObject, configuration: MariaDBTransportConfiguration) async throws -> MobileSchemaSnapshot
    func apply(object: MobileDatabaseObject, baseline: MobileSchemaSnapshot, plan: WorkspaceDatabaseSchemaExecutionPlan,
               configuration: MariaDBTransportConfiguration, authorize: @escaping @Sendable () async throws -> Void) async throws
}
enum MobileSchemaError: LocalizedError {
    case stale, pending, partial(completed: Int, total: Int, detail: String)
    var errorDescription: String? {
        switch self {
        case .stale: "服务器结构或编辑上下文已变化，请核对并重新加载结构。"
        case .pending: "此表有待提交的数据或其他操作，请先提交或撤销。"
        case let .partial(done, total, detail): "已确认完成 \(done)/\(total) 条结构语句；其余结果需核对。请勿重复提交。\n" + detail
        }
    }
}
struct MobileSchemaService: MobileSchemaServicing {
    var makeConnection: @Sendable (MariaDBTransportConfiguration) -> any MobileMutationConnection = {
        MobileMariaDBMutationConnection(client: MariaDBClient(configuration: $0))
    }
    private func client(_ config: MariaDBTransportConfiguration, object: MobileDatabaseObject) throws -> any MobileMutationConnection {
        guard config.tlsMode == .disabled || config.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
        return makeConnection(.init(host: config.host, port: config.port, username: config.username, password: config.password,
                                    database: object.database, tlsMode: config.tlsMode))
    }
    private func read(_ client: any MobileMutationConnection, object: MobileDatabaseObject) async throws -> MobileSchemaSnapshot {
        let fields = try await client.query(MySQLTableSchemaMetadata.columnsQuery(database: object.database, name: object.name), bindings: [])
        let columns = MySQLTableSchemaMetadata.columns(fields.dictionaryRows)
        guard !columns.isEmpty, columns.count == fields.rows.count else { throw MobileQueryError.invalidServerMetadata }
        let qualified = MobileMySQLService.identifier(object.database) + "." + MobileMySQLService.identifier(object.name)
        let indexes: [WorkspaceDatabaseIndex]
        if object.kind == .table {
            indexes = MySQLTableSchemaMetadata.indexes(try await client.query("SHOW INDEX FROM " + qualified, bindings: []).dictionaryRows)
        } else { indexes = [] }
        let text: String
        if object.kind == .table {
            let ddl = try await client.query("SHOW CREATE TABLE " + qualified, bindings: [])
            guard let statement = ddl.rows.first, statement.count >= 2, let value = statement[1] else { throw MobileQueryError.invalidServerMetadata }
            text = value
        } else { text = "" } // Reading view fields must not require SHOW VIEW privilege.
        let options: WorkspaceDatabaseTableOptions?
        if object.kind == .table {
            let result = try await client.query(MySQLTableSchemaMetadata.informationQuery(database: object.database, name: object.name), bindings: [])
            guard let row = result.dictionaryRows.first else { throw MobileQueryError.invalidServerMetadata }
            options = MySQLTableSchemaMetadata.information(row).tableOptions
        } else { options = nil }
        let choices = try await MobileSchemaChoices.load(client, includeEngines: object.kind == .table)
        try Task.checkCancellation()
        return .init(columns: columns, indexes: indexes, choices: choices, ddl: text, options: options)
    }
    func load(object: MobileDatabaseObject, configuration: MariaDBTransportConfiguration) async throws -> MobileSchemaSnapshot {
        let connection = try client(configuration, object: object)
        do { try Task.checkCancellation(); try await connection.connect(); let result = try await read(connection, object: object); await connection.close(); return result }
        catch { await connection.close(); throw error }
    }
    func apply(object: MobileDatabaseObject, baseline: MobileSchemaSnapshot, plan: WorkspaceDatabaseSchemaExecutionPlan,
               configuration: MariaDBTransportConfiguration, authorize: @escaping @Sendable () async throws -> Void) async throws {
        guard object.kind == .table, plan.dialectIdentifier == MySQLSchemaEditingProvider.dialectIdentifier,
              case let .changes(changes) = plan.source, changes.selection == object.editingSelection,
              plan == MySQLSchemaEditingProvider().makeExecutionPlan(for: changes) else { throw MobileSchemaError.stale }
        let connection = try client(configuration, object: object)
        var completed = 0
        do {
            try Task.checkCancellation(); try await authorize(); try await connection.connect()
            let current = try await read(connection, object: object)
            guard baseline.matchesStructure(current) else { throw MobileSchemaError.stale }
            if let change = changes.tableOptionsChange {
                guard baseline.options == change.original, let actual = current.options,
                      change.matchesOriginalChangedValues(in: actual) else { throw MobileSchemaError.stale }
            }
            // Each MySQL DDL commits independently. Never promise rollback or
            // reapply an acknowledged prefix after partial/uncertain failure.
            for statement in plan.statements {
                try Task.checkCancellation(); try await authorize(); try Task.checkCancellation()
                do { _ = try await connection.query(statement.sql, bindings: []) }
                catch {
                    let serverRejected = (error as? CDatabaseClientError).map { !(2000..<3000).contains($0.code) && $0.code != 1317 && $0.sqlState?.hasPrefix("08") != true } == true
                    if serverRejected && completed == 0 { throw error }
                    throw MobileSchemaError.partial(completed: completed, total: plan.statements.count, detail: error.localizedDescription)
                }
                completed += 1
            }
            await connection.close() // An acknowledged final statement is success even after cancellation.
        } catch {
            await connection.close()
            if case MobileSchemaError.partial = error { throw error }
            if completed > 0 {
                throw MobileSchemaError.partial(completed: completed, total: plan.statements.count, detail: error.localizedDescription)
            }
            throw error
        }
    }
}
