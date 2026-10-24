import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

protocol MobileDataImportServicing: Sendable {
    func schema(object: MobileDatabaseObject, configuration: MobileSQLConfiguration) async throws -> WorkspaceDataImportSchema
    func run(object: MobileDatabaseObject, configuration: MobileSQLConfiguration, plan: WorkspaceDataImportPlan,
             authorize: @escaping WorkspaceDataImporter.Authorize,
             progress: @escaping @Sendable (Int) async -> Void) async -> WorkspaceDataImportOutcome
}
struct MobilePostgreSQLImportService: MobileDataImportServicing {
    var makeConnection: @Sendable (MobileSQLConfiguration) -> any MobileMutationConnection = {
        MobilePostgreSQLMutationConnection(client: LibPQClient(configuration: $0.postgreSQL))
    }
    func schema(object: MobileDatabaseObject, configuration: MobileSQLConfiguration) async throws -> WorkspaceDataImportSchema {
        let connection = MobilePostgreSQLImportConnection(client: makeConnection(configuration.selecting(database: object.database, schema: object.schemaName)), object: object)
        do { try await connection.connect(); let schema = try await connection.schema(); await connection.close(); try Task.checkCancellation(); return schema }
        catch { await connection.close(); throw error }
    }
    func run(object: MobileDatabaseObject, configuration: MobileSQLConfiguration, plan: WorkspaceDataImportPlan,
             authorize: @escaping WorkspaceDataImporter.Authorize,
             progress: @escaping @Sendable (Int) async -> Void) async -> WorkspaceDataImportOutcome {
        let connection = MobilePostgreSQLImportConnection(client: makeConnection(configuration.selecting(database: object.database, schema: object.schemaName)), object: object, expected: plan.schema)
        return await WorkspaceDataImporter().run(connection: connection, plan: plan, authorize: authorize, progress: progress)
    }
}
struct MobilePostgreSQLImportConnection: WorkspaceDataImportConnection {
    let client: any MobileMutationConnection
    let object: MobileDatabaseObject
    var expected: WorkspaceDataImportSchema? = nil
    func connect() async throws { try await client.connect() }
    func prepare() async throws { try await MobilePostgreSQLWrite.configure(client) }
    func schema() async throws -> WorkspaceDataImportSchema {
        guard object.kind == .table, let schema = object.schemaName else { throw WorkspaceDatabaseDataCellEditError.tableRequired }
        let kind = try await client.query("SELECT c.relkind::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=" + PostgreSQLCatalog.literal(schema) + " AND c.relname=" + PostgreSQLCatalog.literal(object.name), bindings: [])
        guard let value = kind.rows.first?.first ?? nil, value == "r" || value == "p" else { throw WorkspaceDatabaseDataCellEditError.tableRequired }
        let result = try await client.query(PostgreSQLCatalog.columnsQuery(schema: schema, name: object.name), bindings: [])
        let columns = result.dictionaryRows.compactMap(PostgreSQLCatalog.column)
        guard !columns.isEmpty, columns.count == result.rows.count else { throw MobileQueryError.invalidServerMetadata }
        return .init(columns: columns, tableParts: [schema, object.name], supportsRollback: true)
    }
    func execute(_ sql: String, kind: SQLStatementKind) async throws -> Int {
        let result = try await client.query(sql, bindings: [])
        if kind == .transaction(.begin), let expected, let schema = object.schemaName {
            _ = try await client.query("LOCK TABLE ONLY " + PostgreSQLDataMutation.TableIdentity(schema: schema, name: object.name).sql + " IN ROW EXCLUSIVE MODE", bindings: [])
            guard try await self.schema() == expected else { throw MobileSchemaError.stale }
        }
        return Int(clamping: result.affectedRows)
    }
    func close() async { await client.close() }
}
