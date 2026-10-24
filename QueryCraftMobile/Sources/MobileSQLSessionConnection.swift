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
                     insertID: result.insertID, transactionState: result.transactionState)
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
        let details = try await MobilePostgreSQLColumnDetails.resolve(result.columns, client: client)
        return .init(columns: result.columns, rowCount: result.rowCount, affectedRows: UInt64(max(0, result.affectedRows)),
                     insertID: 0, transactionState: result.transactionState, columnDetails: details)
    }
    func isDefiniteRejection(_ error: any Error) -> Bool {
        guard let state = (error as? PostgreSQLClientError)?.sqlState else { return false }
        return !state.hasPrefix("08") && !["57P01", "57P02", "57P03"].contains(state)
    }
}
