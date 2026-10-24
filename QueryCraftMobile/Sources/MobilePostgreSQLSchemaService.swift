import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileSchemaDialect: Sendable {
    var driver: MobileDriver = .mysql
    var serverVersion = 0
    var provider: any DatabaseSchemaEditingProvider {
        driver == .postgresql ? PostgreSQLSchemaEditingProvider(capabilities: .init(serverVersion: serverVersion)) : MySQLSchemaEditingProvider()
    }
    var descriptor: WorkspaceDatabaseSchemaEditingDescriptor { provider.descriptor }
}

enum MobilePostgreSQLWrite {
    static func definiteRejection(_ error: any Error) -> Bool {
        guard let state = (error as? PostgreSQLClientError)?.sqlState else { return false }
        return !state.hasPrefix("08") && !["57P01", "57P02", "57P03"].contains(state)
    }
    static func configure(_ client: any MobileMutationConnection) async throws {
        _ = try await client.query("SET standard_conforming_strings TO on", bindings: [])
        _ = try await client.query("SET statement_timeout TO '30s'", bindings: [])
        _ = try await client.query("SET lock_timeout TO '5s'", bindings: [])
    }
}

struct MobilePostgreSQLSchemaService: MobileSchemaServicing {
    var makeConnection: @Sendable (MobileSQLConfiguration) -> any MobileMutationConnection = {
        MobilePostgreSQLMutationConnection(client: LibPQClient(configuration: $0.postgreSQL))
    }
    func read(_ client: any MobileMutationConnection, object: MobileDatabaseObject) async throws -> MobileSchemaSnapshot {
        guard let schema = object.schemaName else { throw MobileQueryError.invalidServerMetadata }
        let relation = try await client.query("SELECT c.relkind::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=" + PostgreSQLCatalog.literal(schema) + " AND c.relname=" + PostgreSQLCatalog.literal(object.name), bindings: [])
        let kind = relation.rows.first?.first ?? nil
        guard object.kind == .table ? (kind == "r" || kind == "p") : (kind == "v" || kind == "m") else { throw MobileQueryError.invalidServerMetadata }
        let fields = try await client.query(PostgreSQLCatalog.columnsQuery(schema: schema, name: object.name), bindings: [])
        let columns = fields.dictionaryRows.compactMap(PostgreSQLCatalog.column)
        guard columns.count == fields.rows.count else { throw MobileQueryError.invalidServerMetadata }
        let indexes = object.kind == .table
            ? PostgreSQLSchemaMetadata.indexes(try await client.query(PostgreSQLSchemaMetadata.indexesQuery(schema: schema, name: object.name), bindings: []).dictionaryRows) : []
        let version = try await client.query("SHOW server_version_num", bindings: [])
        guard let text = version.rows.first?.first ?? nil, let number = Int(text), number > 0 else { throw MobileQueryError.invalidServerMetadata }
        let ddl: String
        if object.kind == .view {
            let qualified = PostgreSQLDataMutation.TableIdentity(schema: schema, name: object.name).sql
            let result = try await client.query("SELECT pg_get_viewdef(" + PostgreSQLCatalog.literal(qualified) + "::regclass, true)::text", bindings: [])
            let body = (result.rows.first?.first ?? nil) ?? ""
            ddl = "CREATE VIEW " + qualified + " AS\n" + body
        } else { ddl = PostgreSQLSchemaMetadata.ddl(schema: schema, name: object.name, columns: columns) }
        return .init(columns: columns, indexes: indexes, choices: .empty, ddl: ddl, serverVersion: number)
    }
    func load(object: MobileDatabaseObject, configuration: MobileSQLConfiguration) async throws -> MobileSchemaSnapshot {
        let client = makeConnection(configuration.selecting(database: object.database, schema: object.schemaName))
        do { try Task.checkCancellation(); try await client.connect(); let snapshot = try await read(client, object: object); await client.close(); try Task.checkCancellation(); return snapshot }
        catch { await client.close(); throw error }
    }
    func apply(object: MobileDatabaseObject, baseline: MobileSchemaSnapshot, plan: WorkspaceDatabaseSchemaExecutionPlan,
               configuration: MobileSQLConfiguration, authorize: @escaping @Sendable () async throws -> Void) async throws {
        guard configuration.driver == .postgresql, object.kind == .table, let schema = object.schemaName,
              case let .changes(changes) = plan.source, changes.selection == object.editingSelection,
              plan == (try MobileSchemaDialect(driver: .postgresql, serverVersion: baseline.serverVersion ?? 0).provider.makeExecutionPlan(for: changes)) else { throw MobileSchemaError.stale }
        let client = makeConnection(configuration.selecting(database: object.database, schema: schema))
        do {
            try Task.checkCancellation(); try await authorize(); try await client.connect(); try await MobilePostgreSQLWrite.configure(client)
            try await PostgreSQLSchemaExecutor.apply(plan, prepare: {
                _ = try await client.query("LOCK TABLE ONLY " + PostgreSQLDataMutation.TableIdentity(schema: schema, name: object.name).sql + " IN ACCESS EXCLUSIVE MODE", bindings: [])
                let current = try await read(client, object: object)
                guard baseline.matchesStructure(current), baseline.serverVersion == current.serverVersion else { throw MobileSchemaError.stale }
            }, execute: { sql in
                if sql != "ROLLBACK" { try Task.checkCancellation(); try await authorize(); try Task.checkCancellation() }
                do { _ = try await client.query(sql, bindings: []) }
                catch {
                    if sql == "COMMIT", !MobilePostgreSQLWrite.definiteRejection(error) {
                        throw MobileSchemaError.partial(completed: 0, total: plan.statements.count, detail: error.localizedDescription)
                    }
                    throw error
                }
            })
            await client.close()
        } catch { await client.close(); throw error }
    }
}
