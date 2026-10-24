import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

protocol MobileNewTableServicing: Sendable {
    func choices(configuration: MobileSQLConfiguration) async throws -> WorkspaceDatabaseSchemaChoices
    func create(plan: WorkspaceDatabaseSchemaExecutionPlan, configuration: MobileSQLConfiguration,
                authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceDatabaseObjectSelection
}

enum MobileNewTableError: LocalizedError {
    case invalidDefinition, outcomeUnknown(String)
    var errorDescription: String? {
        switch self {
        case .invalidDefinition: "请填写表名，并至少保留一个名称和类型完整的字段。"
        case .outcomeUnknown(let detail): "建表结果无法确认，请先核对服务器，勿重复创建。\n" + detail
        }
    }
}

struct MobileNewTableService: MobileNewTableServicing {
    var makeConnection: @Sendable (MobileSQLConfiguration) -> any MobileMutationConnection = {
        MobileMariaDBMutationConnection(client: MariaDBClient(configuration: $0))
    }
    private func connection(_ configuration: MobileSQLConfiguration) throws -> any MobileMutationConnection {
        guard configuration.tlsMode == .disabled || configuration.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
        return makeConnection(configuration)
    }
    func choices(configuration: MobileSQLConfiguration) async throws -> WorkspaceDatabaseSchemaChoices {
        let client = try connection(configuration)
        do {
            try Task.checkCancellation(); try await client.connect()
            let result = try await MobileSchemaChoices.load(client, includeEngines: true)
            await client.close(); try Task.checkCancellation(); return result
        } catch { await client.close(); throw error }
    }
    func create(plan: WorkspaceDatabaseSchemaExecutionPlan, configuration: MobileSQLConfiguration,
                authorize: @escaping @Sendable () async throws -> Void) async throws -> WorkspaceDatabaseObjectSelection {
        guard case let .tableMutation(mutation) = plan.source,
              case let .create(database, name, columns, _, _) = mutation,
              !database.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("\0"), columns.contains(where: { !$0.isDeleted }),
              columns.filter({ !$0.isDeleted }).allSatisfy({ !$0.definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.definition.type.isEmpty }),
              plan == MySQLSchemaEditingProvider().makeExecutionPlan(for: mutation),
              let selection = mutation.resultingSelection, let statement = plan.statements.first, plan.statements.count == 1 else {
            throw MobileNewTableError.invalidDefinition
        }
        let config = MobileSQLConfiguration(host: configuration.host, port: configuration.port, username: configuration.username,
            password: configuration.password, database: database, tlsMode: configuration.tlsMode)
        let client = try connection(config)
        do {
            try Task.checkCancellation(); try await authorize(); try await client.connect()
            try Task.checkCancellation(); try await authorize(); try Task.checkCancellation()
            do { _ = try await client.query(statement.sql, bindings: []) }
            catch {
                if let failure = error as? CDatabaseClientError, !(2000..<3000).contains(failure.code),
                   failure.code != 1317, failure.sqlState?.hasPrefix("08") != true { throw error }
                throw MobileNewTableError.outcomeUnknown(error.localizedDescription)
            }
            await client.close() // Acknowledged DDL remains success after cancellation/backgrounding.
            return selection
        } catch { await client.close(); throw error }
    }
}
