import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobilePostgreSQLNewTableService: MobileNewTableServicing {
    var makeConnection: @Sendable (MobileSQLConfiguration) -> any MobileMutationConnection = {
        MobilePostgreSQLMutationConnection(client: LibPQClient(configuration: $0.postgreSQL))
    }
    func choices(configuration: MobileSQLConfiguration) async throws -> WorkspaceDatabaseSchemaChoices { .empty }
    func serverVersion(configuration: MobileSQLConfiguration) async throws -> Int {
        let client = makeConnection(configuration)
        do {
            try await client.connect(); let value = try await client.query("SHOW server_version_num", bindings: [])
            await client.close(); try Task.checkCancellation()
            guard let text = value.rows.first?.first ?? nil, let number = Int(text), number > 0 else { throw MobileQueryError.invalidServerMetadata }
            return number
        } catch { await client.close(); throw error }
    }
    func create(plan: WorkspaceDatabaseSchemaExecutionPlan, configuration: MobileSQLConfiguration,
                authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceDatabaseObjectSelection {
        guard configuration.driver == .postgresql, case let .tableMutation(mutation) = plan.source,
              case let .create(database, name, columns, _, _) = mutation,
              !database.isEmpty, !name.contains("\0"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              columns.filter({ !$0.isDeleted }).allSatisfy({ !$0.definition.name.isEmpty && !$0.definition.type.isEmpty }),
              let selection = mutation.resultingSelection else { throw MobileNewTableError.invalidDefinition }
        let client = makeConnection(configuration.selecting(database: database, schema: configuration.schemaName))
        do {
            try Task.checkCancellation(); try await authorize(); try await client.connect(); try await MobilePostgreSQLWrite.configure(client)
            let version = try await client.query("SHOW server_version_num", bindings: [])
            guard let raw = version.rows.first?.first ?? nil, let number = Int(raw),
                  plan == (PostgreSQLSchemaEditingProvider(capabilities: .init(serverVersion: number)).makeExecutionPlan(for: mutation)) else { throw MobileNewTableError.invalidDefinition }
            try await PostgreSQLSchemaExecutor.apply(plan, execute: { sql in
                if sql != "ROLLBACK" { try Task.checkCancellation(); try await authorize(); try Task.checkCancellation() }
                do { _ = try await client.query(sql, bindings: []) }
                catch {
                    if sql == "COMMIT", !MobilePostgreSQLWrite.definiteRejection(error) { throw MobileNewTableError.outcomeUnknown(error.localizedDescription) }
                    throw error
                }
            })
            await client.close(); return selection
        } catch { await client.close(); throw error }
    }
}

struct MobilePostgreSQLTableActionService: MobileTableActionServicing {
    var makeConnection: @Sendable (MobileSQLConfiguration) -> any MobileMutationConnection = {
        MobilePostgreSQLMutationConnection(client: LibPQClient(configuration: $0.postgreSQL))
    }
    func inspect(object: MobileDatabaseObject, configuration: MobileSQLConfiguration) async throws -> MobileTableActionInfo {
        guard let schema = object.schemaName, object.kind == .table else { throw WorkspaceTableActionError.unsupported }
        let client = makeConnection(configuration.selecting(database: object.database, schema: schema))
        do {
            try await client.connect()
            let target = PostgreSQLCatalog.literal(PostgreSQLDataMutation.TableIdentity(schema: schema, name: object.name).sql)
            let result = try await client.query("SELECT pg_get_serial_sequence(" + target + ", attname) FROM pg_attribute WHERE attrelid=" + target + "::regclass AND attnum>0 AND NOT attisdropped", bindings: [])
            await client.close(); try Task.checkCancellation()
            return .init(nextAutoIncrement: nil, hasAutoIncrement: result.rows.contains { ($0.first ?? nil) != nil })
        } catch { await client.close(); throw error }
    }
    func perform(action: WorkspaceTableAction, object: MobileDatabaseObject, input: String, configuration: MobileSQLConfiguration,
                 authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceTableActionStatement {
        guard configuration.driver == .postgresql, let schema = object.schemaName, object.kind == .table else { throw WorkspaceTableActionError.unsupported }
        let statement = try WorkspaceTableActionStatement.make(action: action, selection: object.editingSelection, databaseType: .postgresql, input: input)
        let client = makeConnection(configuration.selecting(database: object.database, schema: schema))
        do {
            try Task.checkCancellation(); try await authorize(); try await client.connect(); try await MobilePostgreSQLWrite.configure(client)
            try Task.checkCancellation(); try await authorize(); try Task.checkCancellation()
            do { _ = try await client.query(statement.sql, bindings: []) }
            catch {
                if MobilePostgreSQLWrite.definiteRejection(error) { throw error }
                throw MobileTableActionError.outcomeUnknown(error.localizedDescription)
            }
            await client.close(); return statement
        } catch { await client.close(); throw error }
    }
}
