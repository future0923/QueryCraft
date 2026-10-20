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
        if sql == "ROLLBACK" || sql == "ROLLBACK;" {
            return try await runOnQueue {
                guard let connection = self.connection else { throw WorkspaceSessionError.notConnected }
                return try self.query(sql, connection: connection)
            }
        }
        let cancellation = LibPQCopyCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let result = try await runOnQueue {
                    guard let connection = self.connection else { throw WorkspaceSessionError.notConnected }
                    try cancellation.install(connection)
                    defer { cancellation.finish() }
                    return try self.query(sql, connection: connection)
                }
                try Task.checkCancellation(); return result
            } catch {
                if Task.isCancelled { throw CancellationError() }; throw error
            }
        } onCancel: { cancellation.cancel() }
    }

    func copyFrom(sql: String, stream: WorkspaceNativeBulkStream) async throws -> Int {
        let cancellation = LibPQCopyCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await runOnQueue {
                guard let connection = self.connection else { throw WorkspaceSessionError.notConnected }
                try cancellation.install(connection)
                defer { cancellation.finish() }
                guard let result = sql.withCString({ PQexec(connection, $0) }) else {
                    throw self.connectionError(from: connection)
                }
                let status = PQresultStatus(result)
                let error = status == PGRES_COPY_IN ? nil : self.resultError(from: result)
                PQclear(result)
                if let error { throw error }
                var copyEnded = false
                do {
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = try bytes.withUnsafeMutableBytes { try stream.read(into: $0) }
                        if count == 0 { break }
                        let sent = bytes.withUnsafeBytes {
                            PQputCopyData(connection, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(count))
                        }
                        guard sent == 1 else { throw self.connectionError(from: connection) }
                    }
                    try stream.checkFailure()
                    guard PQputCopyEnd(connection, nil) == 1 else { throw self.connectionError(from: connection) }
                    copyEnded = true
                    var rows: Int?, failure: PostgreSQLClientError?
                    // Drain every result before returning the connection to SQL/ROLLBACK.
                    while let final = PQgetResult(connection) {
                        if PQresultStatus(final) == PGRES_COMMAND_OK { rows = self.affectedRows(from: final) }
                        else { failure = self.resultError(from: final) }
                        PQclear(final)
                    }
                    try stream.checkFailure()
                    if let failure { throw failure }
                    guard let rows else { throw self.connectionError(from: connection) }
                    return rows
                } catch {
                    if !copyEnded {
                        _ = "QueryCraft transfer aborted".withCString { PQputCopyEnd(connection, $0) }
                    }
                    while let final = PQgetResult(connection) { PQclear(final) }
                    throw error
                }
            }
        } onCancel: {
            stream.fail(CancellationError()); cancellation.cancel()
        }
    }

    func copyTo(sql: String, stream: WorkspaceNativeBulkStream,
                onProgress: @escaping @Sendable (Int) async -> Void) async throws -> Int {
        let cancellation = LibPQCopyCancellation()
        defer { cancellation.finish() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await runOnQueue {
                guard let connection = self.connection else { throw WorkspaceSessionError.notConnected }
                try cancellation.install(connection)
                guard let result = sql.withCString({ PQexec(connection, $0) }) else { throw self.connectionError(from: connection) }
                defer { PQclear(result) }
                guard PQresultStatus(result) == PGRES_COPY_OUT else { throw self.resultError(from: result) }
            }
            do {
                var rows = 0
                while true {
                    try Task.checkCancellation(); try stream.checkFailure()
                    let batch: (Data, Int, Bool) = try await runOnQueue {
                        guard let connection = self.connection else { throw WorkspaceSessionError.notConnected }
                        var data = Data(); data.reserveCapacity(256 * 1024)
                        var count = 0
                        while data.count < 256 * 1024 {
                            var pointer: UnsafeMutablePointer<CChar>?
                            let length = PQgetCopyData(connection, &pointer, 0)
                            if length == -1 {
                                var failure: PostgreSQLClientError?
                                while let result = PQgetResult(connection) {
                                    if PQresultStatus(result) != PGRES_COMMAND_OK { failure = self.resultError(from: result) }
                                    PQclear(result)
                                }
                                if let failure { throw failure }
                                return (data, count, true)
                            }
                            guard length > 0, let pointer else { throw self.connectionError(from: connection) }
                            data.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(length))
                            PQfreemem(pointer)
                            // COPY text returns one complete escaped row per message.
                            count += 1
                        }
                        return (data, count, false)
                    }
                    try await stream.send(batch.0)
                    rows += batch.1; await onProgress(rows)
                    if batch.2 { break }
                }
                cancellation.finish()
                return rows
            } catch {
                // A failed target must also terminate a producer blocked in COPY OUT.
                cancellation.cancel()
                await runOnQueueIgnoringError {
                    guard let connection = self.connection else { return }
                    cancellation.finish()
                    // This read-only source connection is dedicated to the transfer.
                    // Closing avoids draining an entire remaining table on failure.
                    PQfinish(connection); self.connection = nil
                }
                throw error
            }
        } onCancel: { stream.fail(CancellationError()); cancellation.cancel() }
    }

    func streamTransferRows(sql: String, batchSize: Int,
                            onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> Int {
        let channel = WorkspaceTransferBatchChannel(), cancellation = LibPQCopyCancellation()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    do {
                        return try await self.runOnQueue {
                            guard let connection = self.connection else { throw WorkspaceSessionError.notConnected }
                            try cancellation.install(connection)
                            defer { cancellation.finish() }
                            do {
                                guard sql.withCString({ PQsendQuery(connection, $0) }) == 1,
                                      PQsetSingleRowMode(connection) == 1 else { throw self.connectionError(from: connection) }
                                var columns: [WorkspaceDatabaseDataColumn] = [], rows: [WorkspaceDatabaseDataRow] = []
                                var total = 0, bytes = 0, finished = false
                                let limit = max(1, min(batchSize, 10_000)); rows.reserveCapacity(limit)
                                while let result = PQgetResult(connection) {
                                    let status = PQresultStatus(result)
                                    guard status == PGRES_SINGLE_TUPLE || status == PGRES_TUPLES_OK else {
                                        let error = self.resultError(from: result); PQclear(result); throw error
                                    }
                                    if columns.isEmpty {
                                        columns = (0..<Int(PQnfields(result))).map { index in
                                            WorkspaceDatabaseDataColumn(id: index, name: self.string(from: PQfname(result, Int32(index))) ?? "column_\(index)")
                                        }
                                    }
                                    if status == PGRES_SINGLE_TUPLE {
                                        var cells: [WorkspaceDatabaseDataCell] = []; cells.reserveCapacity(columns.count)
                                        for index in columns.indices {
                                            if PQgetisnull(result, 0, Int32(index)) == 1 { cells.append(.null) }
                                            else {
                                                cells.append(.text(self.string(from: PQgetvalue(result, 0, Int32(index))) ?? ""))
                                                bytes += Int(PQgetlength(result, 0, Int32(index)))
                                            }
                                        }
                                        rows.append(.init(id: total, values: cells)); total += 1
                                    } else { finished = true }
                                    PQclear(result)
                                    if rows.count == limit || bytes >= 1_048_576 {
                                        try channel.send(.init(columns: columns, rows: rows)); rows = []; rows.reserveCapacity(limit); bytes = 0
                                    }
                                }
                                guard finished else { throw self.connectionError(from: connection) }
                                if !rows.isEmpty || total == 0 { try channel.send(.init(columns: columns, rows: rows)) }
                                channel.finish(); return total
                            } catch {
                                cancellation.finish()
                                // A dedicated read-only connection can be discarded rather
                                // than draining the rest of an unbounded source query.
                                PQfinish(connection); self.connection = nil; throw error
                            }
                        }
                    } catch { channel.fail(error); throw error }
                }
                group.addTask {
                    do {
                        var total = 0
                        while let batch = try await channel.next() {
                            try Task.checkCancellation(); try await onBatch(batch); total += batch.rows.count
                        }
                        return total
                    } catch { channel.fail(error); throw error }
                }
                do {
                    var counts: [Int] = []
                    for try await count in group { counts.append(count) }
                    guard counts.count == 2, counts[0] == counts[1] else { throw WorkspaceNativeBulkError.invalidStreamState }
                    try Task.checkCancellation(); return counts[0]
                } catch { channel.fail(error); group.cancelAll(); throw error }
            }
        } onCancel: { channel.fail(CancellationError()); cancellation.cancel() }
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
                affectedRows: affectedRows(from: result),
                transactionState: try Self.transactionState(status: PQtransactionStatus(connection))
            )
        case PGRES_TUPLES_OK:
            // Snapshot before the metadata queries performed by fetchRows.
            let state = try Self.transactionState(status: PQtransactionStatus(connection))
            return fetchRows(from: result, connection: connection, transactionState: state)
        default:
            throw resultError(from: result)
        }
    }

    static func transactionState(status: PGTransactionStatusType) throws -> WorkspaceQueryTransactionState {
        switch status {
        case PQTRANS_IDLE: .autoCommit
        case PQTRANS_INTRANS, PQTRANS_INERROR: .inTransaction
        default: throw WorkspaceSessionError.transactionStateUnavailable
        }
    }

    private func fetchRows(
        from result: OpaquePointer,
        connection: OpaquePointer,
        transactionState: WorkspaceQueryTransactionState
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
            rows: rows,
            transactionState: transactionState
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

/// PQcancel is explicitly safe on a different thread. All pointer lifetime and
/// cancellation state is serialized by this lock; finish prevents late cancellation
/// from accidentally cancelling the following ROLLBACK/COMMIT.
private final class LibPQCopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var cancelled = false

    func install(_ connection: OpaquePointer) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        handle = PQgetCancel(connection)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if let handle { PQfreeCancel(handle) }; handle = nil
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock(); defer { self.lock.unlock() }
            guard let handle = self.handle else { return }
            var error = [CChar](repeating: 0, count: 256)
            _ = PQcancel(handle, &error, Int32(error.count))
        }
    }
}
