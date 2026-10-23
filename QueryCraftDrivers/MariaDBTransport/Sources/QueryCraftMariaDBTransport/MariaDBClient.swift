import CMariaDB
import Darwin
import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#elseif canImport(QueryCraftMobileCore)
import QueryCraftMobileCore
#endif

// Keep the source-facing name. V4 can coexist with older installed driver
// transports; V3 does not export the typed streaming API.
public typealias MariaDBClient = MariaDBConnection

public final class MariaDBConnection: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.future0923.QueryCraft.Driver.MariaDBClient",
        qos: .userInitiated
    )
    private let configuration: MariaDBTransportConfiguration
    private var handle: UnsafeMutablePointer<MYSQL>?
    private var cachedServerVersion: String?

    public init(configuration: MariaDBTransportConfiguration) {
        self.configuration = configuration
    }

    public func connect() async throws {
        try await runOnQueue {
            if self.handle != nil { return }
            self.handle = try self.openConnection(database: self.configuration.database)
            self.cachedServerVersion = self.string(
                from: self.handle.flatMap(mysql_get_server_info)
            )
        }
    }

    public func isConnected() async -> Bool {
        await runOnQueueReturningFalseOnError {
            self.handle != nil && mysql_ping(self.handle) == 0
        }
    }

    public func serverVersion() async -> String? {
        await runOnQueueReturningNilOnError {
            self.cachedServerVersion
        }
    }

    public func connectionID() async throws -> Int {
        try await runOnQueue {
            guard let handle = self.handle else {
                throw WorkspaceSessionError.notConnected
            }
            return Int(mysql_thread_id(handle))
        }
    }

    public func query(_ sql: String) async throws -> CDatabaseQueryResult {
        try await cancellableQuery(sql, bindings: nil)
    }

    /// Retains bounded rows/bytes. Truncating discards the connection rather than
    /// draining an arbitrarily large unbuffered response. Call connect to reuse.
    public func queryPreview(_ sql: String, maximumRows: Int = 500,
                             maximumBytes: Int = 4_194_304) async throws -> CDatabaseQueryPreview {
        let cancellation = MariaDBLoadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let preview = try await runOnQueue {
                    guard let handle = self.handle else { throw WorkspaceSessionError.notConnected }
                    try cancellation.install(Int(mysql_thread_id(handle)))
                    defer { cancellation.finish() }
                    return try self.readQuery(sql, handle: handle,
                        limits: (max(1, min(maximumRows, 10_000)), max(1, min(maximumBytes, 16_777_216))))
                }
                try Task.checkCancellation()
                return preview
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            cancellation.cancel { id in
                guard let killer = try? self.openConnection(database: nil) else { return }
                defer { mysql_close(killer) }
                _ = try? self.query("KILL QUERY \(id)", handle: killer)
            }
        }
    }

    /// Capture status on the transport queue together with the completed result.
    /// Keep the existing result ABI intact for independently upgraded drivers.
    public func queryWithTransactionState(
        _ sql: String
    ) async throws -> (result: CDatabaseQueryResult, transactionState: WorkspaceQueryTransactionState) {
        try await cancellableQueryWithTransactionState(sql, bindings: nil)
    }

    public static func transactionState(serverStatus: UInt32) -> WorkspaceQueryTransactionState {
        serverStatus & UInt32(SERVER_STATUS_IN_TRANS) == 0 ? .autoCommit : .inTransaction
    }

    /// Unbuffered typed results with one-batch backpressure. An interrupted
    /// response discards the connection, so unread packets can never be reused.
    public func queryStream(_ sql: String, maximumRowBytes: Int? = nil,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> CDatabaseQueryStreamResult {
        let channel = WorkspaceTransferBatchChannel(), cancellation = MariaDBLoadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: CDatabaseQueryStreamResult?.self) { group in
                group.addTask {
                    do {
                        return try await self.runOnQueue {
                            guard let handle = self.handle else { throw WorkspaceSessionError.notConnected }
                            try cancellation.install(Int(mysql_thread_id(handle)))
                            defer { cancellation.finish() }
                            guard sql.withCString({ mysql_real_query(handle, $0, UInt(sql.utf8.count)) }) == 0 else {
                                throw self.error(from: handle)
                            }
                            guard let result = mysql_use_result(handle) else {
                                guard mysql_field_count(handle) == 0 else { throw self.error(from: handle) }
                                let summary = CDatabaseQueryStreamResult(columns: [], rowCount: 0,
                                    affectedRows: mysql_affected_rows(handle), insertID: mysql_insert_id(handle),
                                    transactionState: Self.transactionState(serverStatus: handle.pointee.server_status))
                                channel.finish()
                                return summary
                            }
                            var complete = false
                            defer {
                                if !complete { _ = Darwin.shutdown(Int32(mysql_get_socket(handle)), SHUT_RDWR) }
                                mysql_free_result(result)
                                if !complete { mysql_close(handle); self.handle = nil; self.cachedServerVersion = nil }
                            }
                            let count = Int(mysql_num_fields(result)), fields = mysql_fetch_fields(result)
                            let columns = (0..<count).map { index -> WorkspaceDatabaseDataColumn in
                                guard let field = fields?[index] else { return .init(id: index, name: "column_\(index)") }
                                let origin: WorkspaceDatabaseDataColumn.Origin?
                                if let db = field.db, let table = field.org_table, let name = field.org_name,
                                   db.pointee != 0, table.pointee != 0, name.pointee != 0 {
                                    origin = .init(databaseName: String(cString: db), tableName: String(cString: table), columnName: String(cString: name))
                                } else { origin = nil }
                                return .init(id: index, name: String(cString: field.name), type: MariaDBColumnType.name(for: field), origin: origin)
                            }
                            var rows: [WorkspaceDatabaseDataRow] = [], total = 0, bytes = 0
                            while let values = mysql_fetch_row(result) {
                                let lengths = mysql_fetch_lengths(result)
                                if let maximumRowBytes {
                                    var rowBytes = 0
                                    for index in 0..<count {
                                        let length = Int(clamping: lengths?[index] ?? 0)
                                        guard length <= maximumRowBytes - rowBytes else { throw CDatabaseQueryStreamError.rowTooLarge }
                                        rowBytes += length
                                    }
                                }
                                var cells: [WorkspaceDatabaseDataCell] = []
                                for index in 0..<count {
                                    guard let value = values[index] else { cells.append(.null); continue }
                                    let length = Int(clamping: lengths?[index] ?? 0)
                                    let buffer = UnsafeRawBufferPointer(start: value, count: length)
                                    let binary = fields.map { $0[index].charsetnr == 63 && [MYSQL_TYPE_TINY_BLOB, MYSQL_TYPE_MEDIUM_BLOB,
                                        MYSQL_TYPE_LONG_BLOB, MYSQL_TYPE_BLOB, MYSQL_TYPE_STRING, MYSQL_TYPE_VAR_STRING,
                                        MYSQL_TYPE_VARCHAR, MYSQL_TYPE_GEOMETRY, MYSQL_TYPE_BIT].contains($0[index].type) } ?? false
                                    cells.append(binary ? .binary(byteCount: length, preview: Array(buffer.prefix(128))) :
                                        .text(String(bytes: buffer, encoding: .utf8) ?? String(bytes: buffer, encoding: .isoLatin1) ?? ""))
                                    bytes += binary ? min(length, 128) : length
                                }
                                rows.append(.init(id: total, values: cells)); total += 1
                                if rows.count >= 500 || bytes >= 1_048_576 {
                                    try channel.send(.init(columns: columns, rows: rows)); rows = []; bytes = 0
                                }
                            }
                            guard mysql_errno(handle) == 0 else { throw self.error(from: handle) }
                            if !rows.isEmpty || total == 0 { try channel.send(.init(columns: columns, rows: rows)) }
                            let summary = CDatabaseQueryStreamResult(columns: columns, rowCount: total,
                                affectedRows: 0, insertID: mysql_insert_id(handle),
                                transactionState: Self.transactionState(serverStatus: handle.pointee.server_status))
                            complete = true; channel.finish(); return summary
                        }
                    } catch { channel.fail(error); throw error }
                }
                group.addTask {
                    do {
                        while let batch = try await channel.next() { try await onBatch(batch) }
                        return nil
                    } catch { channel.fail(error); throw error }
                }
                do {
                    var summary: CDatabaseQueryStreamResult?
                    for try await result in group { if let result { summary = result } }
                    guard let summary else { throw WorkspaceNativeBulkError.invalidStreamState }
                    // An acknowledged write stays acknowledged if cancellation races
                    // with its OK packet. The caller must never replay it automatically.
                    return summary
                } catch { channel.fail(error); group.cancelAll(); throw error }
            }
        } onCancel: {
            channel.fail(CancellationError())
            cancellation.cancel { id in
                guard let killer = try? self.openConnection(database: nil) else { return }
                defer { mysql_close(killer) }; _ = try? self.query("KILL QUERY \(id)", handle: killer)
            }
        }
    }

    public func loadLocal(sql: String, token: String, stream: WorkspaceNativeBulkStream) async throws -> Int {
        let cancellation = MariaDBLoadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await runOnQueue {
                guard let handle = self.handle else { throw WorkspaceSessionError.notConnected }
                try cancellation.install(Int(mysql_thread_id(handle)))
                defer { cancellation.finish() }
                let input = MariaDBLocalInput(token: token, stream: stream)
                let pointer = Unmanaged.passUnretained(input).toOpaque()
                self.installLocalHandler(handle, context: pointer)
                // Never restore the library's default handler, which opens files.
                defer { self.installLocalHandler(handle, context: nil); withExtendedLifetime(input) {} }
                let result: CDatabaseQueryResult
                do { result = try self.query(sql, handle: handle) }
                catch { try stream.checkFailure(); throw error }
                try stream.checkFailure()
                if let error = input.error { throw error }
                if mysql_warning_count(handle) != 0 {
                    let warnings = try self.query("SHOW WARNINGS LIMIT 5", handle: handle)
                    throw WorkspaceNativeBulkError.serverWarning(warnings.rows.map { $0.compactMap { $0 }.joined(separator: ": ") }.joined(separator: "; "))
                }
                guard let rows = Int(exactly: result.affectedRows) else {
                    throw WorkspaceNativeBulkError.invalidStreamState
                }
                return rows
            }
        } onCancel: {
            stream.fail(CancellationError())
            cancellation.cancel { id in
                // A separate connection interrupts lock waits / blocked server work.
                // finish waits for this request before allowing the subsequent rollback.
                guard let killer = try? self.openConnection(database: nil) else { return }
                defer { mysql_close(killer) }
                _ = try? self.query("KILL QUERY \(id)", handle: killer)
            }
        }
    }

    public func streamTransferRows(sql: String, batchSize: Int,
                                    onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> Int {
        let channel = WorkspaceTransferBatchChannel(), cancellation = MariaDBLoadCancellation()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    do {
                        return try await self.runOnQueue {
                            guard let handle = self.handle else { throw WorkspaceSessionError.notConnected }
                            try cancellation.install(Int(mysql_thread_id(handle)))
                            defer { cancellation.finish() }
                            guard sql.withCString({ mysql_real_query(handle, $0, UInt(sql.utf8.count)) }) == 0 else { throw self.error(from: handle) }
                            guard let result = mysql_use_result(handle) else { throw self.error(from: handle) }
                            defer { mysql_free_result(result) }
                            let count = Int(mysql_num_fields(result)), fields = mysql_fetch_fields(result)
                            let columns = (0..<count).map { index in
                                WorkspaceDatabaseDataColumn(id: index, name: fields.map { String(cString: $0[index].name) } ?? "column_\(index)")
                            }
                            var rows: [WorkspaceDatabaseDataRow] = [], total = 0, bytes = 0
                            let limit = max(1, min(batchSize, 10_000))
                            rows.reserveCapacity(limit)
                            do {
                                while let values = mysql_fetch_row(result) {
                                    let lengths = mysql_fetch_lengths(result)
                                    var cells: [WorkspaceDatabaseDataCell] = []; cells.reserveCapacity(count)
                                    for index in 0..<count {
                                        guard let value = values[index] else { cells.append(.null); continue }
                                        let length = Int(clamping: lengths?[index] ?? 0)
                                        guard let text = String(bytes: UnsafeRawBufferPointer(start: value, count: length), encoding: .utf8) else {
                                            throw WorkspaceNativeBulkError.invalidTextEncoding
                                        }
                                        cells.append(.text(text)); bytes += length
                                    }
                                    rows.append(.init(id: total, values: cells)); total += 1
                                    if rows.count == limit || bytes >= 1_048_576 {
                                        try channel.send(.init(columns: columns, rows: rows)); rows = []; rows.reserveCapacity(limit); bytes = 0
                                    }
                                }
                                guard mysql_errno(handle) == 0 else { throw self.error(from: handle) }
                                // Even an empty table must expose its actual result columns.
                                if !rows.isEmpty || total == 0 { try channel.send(.init(columns: columns, rows: rows)) }
                                channel.finish(); return total
                            } catch {
                                // Do not drain a multi-billion-row unbuffered result on failure.
                                cancellation.finish()
                                if let killer = try? self.openConnection(database: nil) {
                                    _ = try? self.query("KILL QUERY \(mysql_thread_id(handle))", handle: killer); mysql_close(killer)
                                }
                                throw error
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
        } onCancel: {
            channel.fail(CancellationError())
            cancellation.cancel { id in
                guard let killer = try? self.openConnection(database: nil) else { return }
                defer { mysql_close(killer) }; _ = try? self.query("KILL QUERY \(id)", handle: killer)
            }
        }
    }

    private func installLocalHandler(_ handle: UnsafeMutablePointer<MYSQL>, context: UnsafeMutableRawPointer?) {
        mysql_set_local_infile_handler(handle, { output, filename, user in
            output?.pointee = user
            guard let user, let filename else { return 1 }
            let input = Unmanaged<MariaDBLocalInput>.fromOpaque(user).takeUnretainedValue()
            guard String(cString: filename) == input.token else {
                input.error = WorkspaceNativeBulkError.invalidLocalRequest; return 1
            }
            return 0
        }, { user, bytes, length in
            guard let user, let bytes else { return -1 }
            let input = Unmanaged<MariaDBLocalInput>.fromOpaque(user).takeUnretainedValue()
            do { return Int32(try input.stream.read(into: .init(start: bytes, count: Int(length)))) }
            catch { input.error = error; return -1 }
        }, { _ in }, { user, buffer, length in
            let message: String
            if let user {
                message = Unmanaged<MariaDBLocalInput>.fromOpaque(user).takeUnretainedValue().error?.localizedDescription ?? "LOCAL INFILE stream failed."
            } else { message = "LOCAL INFILE filesystem access is disabled." }
            if let buffer, length > 0 {
                let bytes = Array(message.utf8.prefix(Int(length) - 1))
                for index in bytes.indices { buffer[index] = CChar(bitPattern: bytes[index]) }
                buffer[bytes.count] = 0
            }
            return 1
        }, context)
    }

    public func query(
        _ sql: String,
        bindings: [WorkspaceDatabaseDataCell]
    ) async throws -> CDatabaseQueryResult {
        try await cancellableQuery(sql, bindings: bindings)
    }

    private func cancellableQuery(_ sql: String, bindings: [WorkspaceDatabaseDataCell]?) async throws -> CDatabaseQueryResult {
        try await cancellableQueryWithTransactionState(sql, bindings: bindings).result
    }

    private func cancellableQueryWithTransactionState(
        _ sql: String, bindings: [WorkspaceDatabaseDataCell]?
    ) async throws -> (result: CDatabaseQueryResult, transactionState: WorkspaceQueryTransactionState) {
        // Driver catch/defer cleanup must still roll back a cancelled task.
        if bindings == nil && (sql == "ROLLBACK" || sql == "ROLLBACK;") {
            return try await runOnQueue {
                guard let handle = self.handle else { throw WorkspaceSessionError.notConnected }
                let result = try self.query(sql, handle: handle)
                return (result, Self.transactionState(serverStatus: handle.pointee.server_status))
            }
        }
        let cancellation = MariaDBLoadCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let result = try await runOnQueue {
                    guard let handle = self.handle else { throw WorkspaceSessionError.notConnected }
                    try cancellation.install(Int(mysql_thread_id(handle)))
                    defer { cancellation.finish() }
                    let statement = try bindings.map { try self.resolvePlaceholders(in: sql, bindings: $0, handle: handle) } ?? sql
                    let result = try self.query(statement, handle: handle)
                    return (result, Self.transactionState(serverStatus: handle.pointee.server_status))
                }
                try Task.checkCancellation(); return result
            } catch {
                if Task.isCancelled { throw CancellationError() }; throw error
            }
        } onCancel: {
            cancellation.cancel { id in
                guard let killer = try? self.openConnection(database: nil) else { return }
                defer { mysql_close(killer) }; _ = try? self.query("KILL QUERY \(id)", handle: killer)
            }
        }
    }

    public func close() async {
        await runOnQueueIgnoringError {
            if let handle = self.handle {
                mysql_close(handle)
                self.handle = nil
            }
        }
    }

    private func openConnection(
        database: String?
    ) throws -> UnsafeMutablePointer<MYSQL> {
        guard let mysql = mysql_init(nil) else {
            throw CDatabaseClientError(
                code: 0,
                message: "Failed to initialize MariaDB client.",
                sqlState: nil
            )
        }

        var reconnect: my_bool = 0
        mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect)

        var timeout: UInt32 = 10
        mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        mysql_options(mysql, MYSQL_OPT_READ_TIMEOUT, &timeout)
        mysql_options(mysql, MYSQL_OPT_WRITE_TIMEOUT, &timeout)

        var protocolTCP = UInt32(MYSQL_PROTOCOL_TCP.rawValue)
        mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocolTCP)
        mysql_options(mysql, MYSQL_SET_CHARSET_NAME, "utf8mb4")
        // Negotiate LOCAL support, but deny all resource requests by default.
        // Only loadLocal temporarily installs a token-scoped memory stream.
        var local: UInt32 = 1
        mysql_options(mysql, MYSQL_OPT_LOCAL_INFILE, &local)
        installLocalHandler(mysql, context: nil)

        switch configuration.tlsMode {
        case .disabled:
            var sslEnforce: my_bool = 0
            mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
            var verify: my_bool = 0
            mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify)
        case .required, .verifyCA, .verifyIdentity:
            var sslEnforce: my_bool = 1
            mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
            var verify: my_bool = configuration.tlsMode == .verifyIdentity
                || configuration.tlsMode == .verifyCA ? 1 : 0
            mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify)
        }

        let db = database?.isEmpty == false ? database : nil
        let password = configuration.password?.isEmpty == false
            ? configuration.password
            : nil

        let connected: UnsafeMutablePointer<MYSQL>? = configuration.host
            .withCString { hostPointer in
                configuration.username.withCString { userPointer in
                    let connectWithPassword: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<MYSQL>? = {
                        passwordPointer in
                        if let db {
                            return db.withCString { dbPointer in
                                mysql_real_connect(
                                    mysql,
                                    hostPointer,
                                    userPointer,
                                    passwordPointer,
                                    dbPointer,
                                    UInt32(self.configuration.port),
                                    nil,
                                    0
                                )
                            }
                        }
                        return mysql_real_connect(
                            mysql,
                            hostPointer,
                            userPointer,
                            passwordPointer,
                            nil,
                            UInt32(self.configuration.port),
                            nil,
                            0
                        )
                    }

                    if let password {
                        return password.withCString(connectWithPassword)
                    }
                    return connectWithPassword(nil)
                }
            }

        guard let connected else {
            let error = self.error(from: mysql)
            mysql_close(mysql)
            throw error
        }
        return connected
    }

    private func query(
        _ sql: String,
        handle: UnsafeMutablePointer<MYSQL>
    ) throws -> CDatabaseQueryResult {
        try readQuery(sql, handle: handle, limits: nil).result
    }

    private func readQuery(_ sql: String, handle: UnsafeMutablePointer<MYSQL>,
                           limits: (rows: Int, bytes: Int)?) throws -> CDatabaseQueryPreview {
        let status = sql.withCString { sqlPointer in
            mysql_real_query(handle, sqlPointer, UInt(sql.utf8.count))
        }
        guard status == 0 else {
            throw error(from: handle)
        }

        guard let result = mysql_use_result(handle) else {
            let fieldCount = mysql_field_count(handle)
            guard fieldCount == 0 else {
                throw error(from: handle)
            }
            return CDatabaseQueryPreview(result: CDatabaseQueryResult(
                affectedRows: mysql_affected_rows(handle),
                insertID: mysql_insert_id(handle)
            ))
        }
        var truncated = false
        defer {
            if truncated {
                // Use the public socket API; never edit opaque MYSQL/RESULT fields.
                // Shut down IO first so free_result cannot drain millions of rows.
                _ = Darwin.shutdown(mysql_get_socket(handle), SHUT_RDWR)
            }
            mysql_free_result(result)
            if truncated {
                mysql_close(handle)
                self.handle = nil
                cachedServerVersion = nil
            }
        }

        let columnCount = Int(mysql_num_fields(result))
        let fields = mysql_fetch_fields(result)
        let columns = (0..<columnCount).map { index in
            fields.map { String(cString: $0[index].name) } ?? "column_\(index)"
        }
        let columnTypes = (0..<columnCount).map { index in
            fields.flatMap { MariaDBColumnType.name(for: $0[index]) }
        }
        let columnOrigins = (0..<columnCount).map { index in
            guard
                let field = fields?[index],
                let database = field.db,
                let table = field.org_table,
                let column = field.org_name
            else {
                return CDatabaseQueryResult.ColumnOrigin?.none
            }
            let databaseName = String(cString: database)
            let tableName = String(cString: table)
            let columnName = String(cString: column)
            guard
                !databaseName.isEmpty,
                !tableName.isEmpty,
                !columnName.isEmpty
            else {
                return CDatabaseQueryResult.ColumnOrigin?.none
            }
            return CDatabaseQueryResult.ColumnOrigin(
                databaseName: databaseName,
                tableName: tableName,
                columnName: columnName
            )
        }

        var rows: [[String?]] = []
        var cells: [[WorkspaceDatabaseDataCell]] = []
        var retainedBytes = 0
        rows.reserveCapacity(256)

        while let rowPointer = mysql_fetch_row(result) {
            let lengths = mysql_fetch_lengths(result)
            if let limits {
                var rowBytes = 0
                for index in 0..<columnCount {
                    let length = Int(clamping: lengths?[index] ?? 0)
                    guard length <= limits.bytes - rowBytes else { truncated = true; break }
                    rowBytes += length
                }
                if truncated || rows.count >= limits.rows || rowBytes > limits.bytes - retainedBytes {
                    truncated = true
                    break
                }
                retainedBytes += rowBytes
            }
            var row: [String?] = []
            var typedRow: [WorkspaceDatabaseDataCell] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                guard let valuePointer = rowPointer[index] else {
                    row.append(nil)
                    if limits != nil { typedRow.append(.null) }
                    continue
                }
                let length = Int(clamping: lengths?[index] ?? 0)
                let buffer = UnsafeRawBufferPointer(
                    start: valuePointer,
                    count: length
                )
                let value = String(bytes: buffer, encoding: .utf8)
                        ?? String(bytes: buffer, encoding: .isoLatin1)
                        ?? ""
                row.append(value)
                if limits != nil {
                    let isBinary = fields.map { $0[index].charsetnr == 63
                        && [MYSQL_TYPE_TINY_BLOB, MYSQL_TYPE_MEDIUM_BLOB, MYSQL_TYPE_LONG_BLOB,
                            MYSQL_TYPE_BLOB, MYSQL_TYPE_STRING, MYSQL_TYPE_VAR_STRING, MYSQL_TYPE_VARCHAR,
                            MYSQL_TYPE_GEOMETRY, MYSQL_TYPE_BIT].contains($0[index].type) } ?? false
                    typedRow.append(isBinary ? .binary(byteCount: length, preview: Array(buffer.prefix(128))) : .text(value))
                }
            }
            rows.append(row)
            if limits != nil { cells.append(typedRow) }
        }

        let fetchError = mysql_errno(handle)
        guard truncated || fetchError == 0 else {
            throw error(from: handle)
        }

        return CDatabaseQueryPreview(result: CDatabaseQueryResult(
            columns: columns,
            columnTypes: columnTypes,
            columnOrigins: columnOrigins,
            rows: rows
        ), cells: cells, isTruncated: truncated)
    }

    private func resolvePlaceholders(
        in sql: String,
        bindings: [WorkspaceDatabaseDataCell],
        handle: UnsafeMutablePointer<MYSQL>
    ) throws -> String {
        guard !bindings.isEmpty else { return sql }

        var output = ""
        output.reserveCapacity(sql.count + bindings.count * 8)
        var bindingIndex = 0
        for character in sql {
            if character == "?" {
                guard bindingIndex < bindings.count else {
                    throw WorkspaceSessionError.queryUnavailable
                }
                output += try sqlLiteral(
                    for: bindings[bindingIndex],
                    handle: handle
                )
                bindingIndex += 1
            } else {
                output.append(character)
            }
        }
        guard bindingIndex == bindings.count else {
            throw WorkspaceSessionError.queryUnavailable
        }
        return output
    }

    private func sqlLiteral(
        for cell: WorkspaceDatabaseDataCell,
        handle: UnsafeMutablePointer<MYSQL>
    ) throws -> String {
        switch cell {
        case .null:
            return "NULL"
        case let .text(value):
            return "'\(escapedString(value, handle: handle))'"
        case .binary:
            throw WorkspaceDatabaseDataCellEditError.binaryValueUnavailable
        }
    }

    private func escapedString(
        _ value: String,
        handle: UnsafeMutablePointer<MYSQL>
    ) -> String {
        var destination = [CChar](
            repeating: 0,
            count: value.utf8.count * 2 + 1
        )
        return value.withCString { source in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let destinationPointer = destinationBuffer.baseAddress
                else { return "" }
                mysql_real_escape_string(
                    handle,
                    destinationPointer,
                    source,
                    UInt(value.utf8.count)
                )
                return String(cString: destinationPointer)
            }
        }
    }

    private func error(
        from handle: UnsafeMutablePointer<MYSQL>
    ) -> CDatabaseClientError {
        CDatabaseClientError(
            code: mysql_errno(handle),
            message: String(cString: mysql_error(handle)),
            sqlState: string(from: mysql_sqlstate(handle))
        )
    }

    private func string(from pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }

    private func string(from pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: UnsafePointer(pointer))
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
}

// Confined to the MariaDB serial transport queue, including the synchronous C callbacks.
private final class MariaDBLocalInput {
    let token: String
    let stream: WorkspaceNativeBulkStream
    var error: (any Error)?
    init(token: String, stream: WorkspaceNativeBulkStream) { self.token = token; self.stream = stream }
}

/// All state is locked, and a late cancellation cannot target the next statement.
private final class MariaDBLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var id: Int?
    private var cancelled = false
    func install(_ id: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.id = id
    }
    func finish() { lock.lock(); id = nil; lock.unlock() }
    func cancel(_ operation: @escaping @Sendable (Int) -> Void) {
        lock.lock(); cancelled = true; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock(); defer { self.lock.unlock() }
            if let id = self.id { operation(id) }
        }
    }
}
