import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileSQLStreamResult: Sendable {
    let columns: [WorkspaceDatabaseDataColumn]
    let rowCount: Int
    let affectedRows: UInt64
    let insertID: UInt64
    let transactionState: WorkspaceQueryTransactionState
    var columnDetails: [String]? = nil
}

protocol MobileSQLSessionConnection: Sendable {
    func connect() async throws
    func close() async
    func query(_ sql: String) async throws
    func queryStream(_ sql: String, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> MobileSQLStreamResult
    func isDefiniteRejection(_ error: any Error) -> Bool
}

struct MobileMySQLSessionConnection: MobileSQLSessionConnection {
    let configuration: MobileSQLConfiguration
    let client: MariaDBClient
    init(configuration: MobileSQLConfiguration) {
        self.configuration = configuration; client = .init(configuration: configuration)
    }
    func connect() async throws {
        guard configuration.tlsMode == .required || configuration.tlsMode == .disabled else { throw MobileQueryError.verifiedTLSUnavailable }
        try await client.connect()
    }
    func close() async { await client.close() }
    func query(_ sql: String) async throws { _ = try await client.query(sql) }
    func queryStream(_ sql: String, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> MobileSQLStreamResult {
        let result = try await client.queryStream(sql, maximumRowBytes: 8_388_608, onBatch: onBatch)
        return .init(columns: result.columns, rowCount: result.rowCount, affectedRows: result.affectedRows,
                     insertID: result.insertID, transactionState: result.transactionState,
                     columnDetails: try await MobileMariaDBColumnDetails.resolve(result.columns, client: client, configuration: configuration))
    }
    func isDefiniteRejection(_ error: any Error) -> Bool {
        (error as? CDatabaseClientError).map { [1044, 1045, 1054, 1064, 1142, 1143, 1146, 1227].contains(Int($0.code)) } ?? false
    }
}

struct MobilePostgreSQLSessionConnection: MobileSQLSessionConnection {
    let configuration: MobileSQLConfiguration
    let client: LibPQClient
    init(configuration: MobileSQLConfiguration) {
        self.configuration = configuration; client = .init(configuration: configuration.postgreSQL)
    }
    func connect() async throws {
        try await client.connect()
        try await query("SET standard_conforming_strings TO on")
        try await query("SET statement_timeout TO '30s'")
        if let schema = configuration.schemaName { try await query(PostgreSQLCatalog.searchPathQuery(schema: schema, local: false)) }
    }
    func close() async { await client.close() }
    func query(_ sql: String) async throws { _ = try await client.query(sql) }
    func queryStream(_ sql: String, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> MobileSQLStreamResult {
        let result = try await client.queryStream(sql, onBatch: onBatch)
        let details = try await MobilePostgreSQLColumnDetails.resolve(result.columns, client: client, currentDatabase: configuration.database)
        return .init(columns: result.columns, rowCount: result.rowCount, affectedRows: UInt64(max(0, result.affectedRows)),
                     insertID: 0, transactionState: result.transactionState, columnDetails: details)
    }
    func isDefiniteRejection(_ error: any Error) -> Bool {
        guard let state = (error as? PostgreSQLClientError)?.sqlState else { return false }
        return !state.hasPrefix("08") && !["57P01", "57P02", "57P03"].contains(state)
    }
}

/// Same streaming wire implementation; Doris does not support MySQL's read-only
/// transaction commands. The owning session validates every statement first.
struct MobileDorisSessionConnection: MobileSQLSessionConnection {
    private let shared: MobileMySQLSessionConnection
    init(configuration: MobileSQLConfiguration) { shared = .init(configuration: configuration) }
    func connect() async throws { try await shared.connect() }
    func close() async { await shared.close() }
    func query(_ sql: String) async throws {
        try MobileSQLReadPolicy.validate(sql, backslashEscapes: true)
        try MobileSQLReadPolicy.validate(sql, backslashEscapes: false)
        try await shared.query(sql)
    }
    func queryStream(_ sql: String, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> MobileSQLStreamResult {
        try MobileSQLReadPolicy.validate(sql, backslashEscapes: true)
        try MobileSQLReadPolicy.validate(sql, backslashEscapes: false)
        let result = try await shared.client.queryStream(sql, maximumRowBytes: 8_388_608, onBatch: onBatch)
        return .init(columns: result.columns, rowCount: result.rowCount, affectedRows: result.affectedRows, insertID: 0, transactionState: .autoCommit,
                     columnDetails: try await MobileMariaDBColumnDetails.resolve(result.columns, client: shared.client, configuration: shared.configuration, doris: true))
    }
    func isDefiniteRejection(_ error: any Error) -> Bool { shared.isDefiniteRejection(error) }
}


enum MobileMariaDBColumnDetails {
    static func resolve(_ fields: [WorkspaceDatabaseDataColumn], client: MariaDBClient, configuration: MobileSQLConfiguration, doris: Bool = false) async throws -> [String] {
        var details: [WorkspaceDatabaseObjectSelection: [WorkspaceDatabaseColumn]] = [:]
        for selection in WorkspaceQueryResultColumnMetadata.selections(columns: fields, currentDatabase: configuration.database) {
            let sql = doris
                ? "SHOW FULL COLUMNS FROM " + MobileMySQLService.identifier(selection.databaseName) + "." + MobileMySQLService.identifier(selection.objectName)
                : MySQLTableSchemaMetadata.columnsQuery(database: selection.databaseName, name: selection.objectName)
            if let rows = try? await client.query(sql) {
                details[selection] = doris ? DorisSchemaMetadata.columns(rows.dictionaryRows) : MySQLTableSchemaMetadata.columns(rows.dictionaryRows)
            }
            try Task.checkCancellation()
        }
        let metadata = WorkspaceQueryResultColumnMetadata.resolve(columns: fields, currentDatabase: configuration.database, details: details)
        return fields.map { field in
            let detail = metadata[field.id]
            return [detail?.type ?? field.type ?? "", detail?.comment ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}
