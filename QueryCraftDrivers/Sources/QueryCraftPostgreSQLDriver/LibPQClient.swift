import CLibPQ
import Foundation
import QueryCraftFeature

final class LibPQClient: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.future0923.QueryCraft.Driver.LibPQClient",
        qos: .userInitiated
    )
    private let configuration: PostgreSQLConnectionConfiguration
    private var connection: OpaquePointer?
    private var cachedServerVersion: String?
    private var cachedServerVersionNumber: Int32 = 0

    init(configuration: PostgreSQLConnectionConfiguration) {
        self.configuration = configuration
    }

    func connect() async throws {
        try await runOnQueue {
            if self.connection != nil { return }
            let connection = try self.openConnection()
            try self.executeSetup(on: connection)
            self.cacheServerVersion(from: connection)
            self.connection = connection
        }
    }

    func isConnected() async -> Bool {
        await runOnQueueReturningFalseOnError {
            guard let connection = self.connection else { return false }
            return PQstatus(connection) == CONNECTION_OK
        }
    }

    func serverVersion() async -> String? {
        await runOnQueueReturningNilOnError {
            self.cachedServerVersion
        }
    }

    func serverVersionNumber() async -> Int32 {
        await runOnQueueReturningZeroOnError {
            self.cachedServerVersionNumber
        }
    }

    func currentDatabase() async -> String {
        await runOnQueueReturningStringOnError {
            self.configuration.database
        }
    }

    func query(_ sql: String) async throws -> PostgreSQLCQueryResult {
        try await runOnQueue {
            guard let connection = self.connection else {
                throw WorkspaceSessionError.notConnected
            }
            return try self.query(sql, connection: connection)
        }
    }

    func close() async {
        await runOnQueueIgnoringError {
            if let connection = self.connection {
                PQfinish(connection)
                self.connection = nil
            }
        }
    }

    private func openConnection() throws -> OpaquePointer {
        let connectionString = buildConnectionString()
        guard let connection = connectionString.withCString(PQconnectdb) else {
            throw PostgreSQLClientError(
                message: "Failed to initialize PostgreSQL connection.",
                sqlState: nil
            )
        }
        guard PQstatus(connection) == CONNECTION_OK else {
            let error = self.connectionError(from: connection)
            PQfinish(connection)
            throw error
        }
        return connection
    }

    private func executeSetup(on connection: OpaquePointer) throws {
        let result = "SET client_encoding TO 'UTF8'".withCString {
            PQexec(connection, $0)
        }
        guard let result else { throw connectionError(from: connection) }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_COMMAND_OK else {
            throw resultError(from: result)
        }
    }

    private func cacheServerVersion(from connection: OpaquePointer) {
        let version = PQserverVersion(connection)
        cachedServerVersionNumber = version
        guard version > 0 else { return }
        let major = version / 10_000
        if major >= 10 {
            cachedServerVersion = "\(major).\(version % 10_000)"
        } else {
            cachedServerVersion = "\(major).\((version / 100) % 100).\(version % 100)"
        }
    }

    private func buildConnectionString() -> String {
        func escape(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
        }

        var components = [
            "host='\(escape(configuration.host))'",
            "port='\(configuration.port)'",
            "dbname='\(escape(configuration.database))'",
        ]
        if !configuration.username.isEmpty {
            components.append("user='\(escape(configuration.username))'")
        }
        if let password = configuration.password, !password.isEmpty {
            components.append("password='\(escape(password))'")
        }
        components.append("sslmode='\(sslModeString())'")
        return components.joined(separator: " ")
    }

    private func sslModeString() -> String {
        switch configuration.tlsMode {
        case .disabled:
            return "disable"
        case .required:
            return "require"
        case .verifyCA:
            return "verify-ca"
        case .verifyIdentity:
            return "verify-full"
        }
    }

    private func query(
        _ sql: String,
        connection: OpaquePointer
    ) throws -> PostgreSQLCQueryResult {
        guard let result = sql.withCString({ PQexec(connection, $0) }) else {
            throw connectionError(from: connection)
        }
        defer { PQclear(result) }

        switch PQresultStatus(result) {
        case PGRES_COMMAND_OK:
            return PostgreSQLCQueryResult(
                affectedRows: affectedRows(from: result)
            )
        case PGRES_TUPLES_OK:
            return fetchRows(from: result, connection: connection)
        default:
            throw resultError(from: result)
        }
    }

    private func fetchRows(
        from result: OpaquePointer,
        connection: OpaquePointer
    ) -> PostgreSQLCQueryResult {
        let columnCount = Int(PQnfields(result))
        let rowCount = Int(PQntuples(result))
        let columns = (0..<columnCount).map { index in
            string(from: PQfname(result, Int32(index)))
                ?? "column_\(index)"
        }
        let metadata = columnMetadata(from: result, connection: connection)
        let columnTypes = (0..<columnCount).map { metadata[$0]?.type }
        let columnOrigins = (0..<columnCount).map { metadata[$0]?.origin }

        var rows: [[String?]] = []
        rows.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for columnIndex in 0..<columnCount {
                if PQgetisnull(result, Int32(rowIndex), Int32(columnIndex)) == 1 {
                    row.append(nil)
                } else if let value = PQgetvalue(
                    result,
                    Int32(rowIndex),
                    Int32(columnIndex)
                ) {
                    row.append(String(cString: value))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return PostgreSQLCQueryResult(
            columns: columns,
            columnTypes: columnTypes,
            columnOrigins: columnOrigins,
            rows: rows
        )
    }

    private struct ColumnMetadata {
        let type: String?
        let origin: PostgreSQLCQueryResult.ColumnOrigin?
    }

    private func columnMetadata(
        from queryResult: OpaquePointer,
        connection: OpaquePointer
    ) -> [Int: ColumnMetadata] {
        let count = Int(PQnfields(queryResult))
        guard count > 0 else { return [:] }
        // Numeric protocol metadata identifies aliases and expressions without parsing SQL.
        let values: String = (0..<count).map { index -> String in
            let field = Int32(index)
            return "(\(index), \(PQftype(queryResult, field))::oid, \(PQfmod(queryResult, field)), \(PQftable(queryResult, field))::oid, \(PQftablecol(queryResult, field)))"
        }.joined(separator: ",")
        let sql = """
            SELECT
                i.column_index::text,
                pg_catalog.format_type(i.type_oid, i.type_modifier)::text,
                n.nspname::text,
                c.relname::text,
                a.attname::text
            FROM (VALUES \(values)) AS i(column_index, type_oid, type_modifier, table_oid, column_number)
            LEFT JOIN pg_catalog.pg_class c ON c.oid = i.table_oid
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_attribute a
              ON a.attrelid = c.oid AND a.attnum = i.column_number
             AND a.attnum > 0 AND NOT a.attisdropped
            """
        guard let metadata = sql.withCString({ PQexec(connection, $0) }) else {
            return [:]
        }
        defer { PQclear(metadata) }
        guard PQresultStatus(metadata) == PGRES_TUPLES_OK else { return [:] }
        var result: [Int: ColumnMetadata] = [:]
        for row in 0..<Int(PQntuples(metadata)) {
            let rowIndex = Int32(row)
            guard let indexText = string(from: PQgetvalue(metadata, rowIndex, 0)),
                  let index = Int(indexText) else { continue }
            func value(_ column: Int32) -> String? {
                guard PQgetisnull(metadata, rowIndex, column) == 0 else { return nil }
                return string(from: PQgetvalue(metadata, rowIndex, column))
            }
            let origin: PostgreSQLCQueryResult.ColumnOrigin?
            if let schema = value(2), let table = value(3), let column = value(4) {
                origin = .init(schemaName: schema, tableName: table, columnName: column)
            } else {
                origin = nil
            }
            result[index] = ColumnMetadata(type: value(1), origin: origin)
        }
        return result
    }

    private func affectedRows(from result: OpaquePointer) -> Int {
        guard let tuples = PQcmdTuples(result) else { return 0 }
        return Int(String(cString: tuples)) ?? 0
    }

    private func connectionError(from connection: OpaquePointer) -> PostgreSQLClientError {
        PostgreSQLClientError(
            message: string(from: PQerrorMessage(connection))
                ?? "PostgreSQL connection error.",
            sqlState: nil
        )
    }

    private func resultError(from result: OpaquePointer) -> PostgreSQLClientError {
        PostgreSQLClientError(
            message: string(from: PQresultErrorMessage(result))
                ?? "PostgreSQL query error.",
            sqlState: string(from: PQresultErrorField(result, 67))
        )
    }

    private func string(from pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }

    private func runOnQueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOnQueueIgnoringError(
        _ operation: @escaping @Sendable () throws -> Void
    ) async {
        _ = try? await runOnQueue(operation)
    }

    private func runOnQueueReturningFalseOnError(
        _ operation: @escaping @Sendable () throws -> Bool
    ) async -> Bool {
        (try? await runOnQueue(operation)) ?? false
    }

    private func runOnQueueReturningNilOnError<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value?
    ) async -> Value? {
        (try? await runOnQueue(operation)) ?? nil
    }

    private func runOnQueueReturningZeroOnError(
        _ operation: @escaping @Sendable () throws -> Int32
    ) async -> Int32 {
        (try? await runOnQueue(operation)) ?? 0
    }

    private func runOnQueueReturningStringOnError(
        _ operation: @escaping @Sendable () throws -> String
    ) async -> String {
        (try? await runOnQueue(operation)) ?? ""
    }
}
