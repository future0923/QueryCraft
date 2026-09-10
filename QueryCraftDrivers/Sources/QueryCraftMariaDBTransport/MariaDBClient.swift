import CMariaDB
import Foundation
import QueryCraftFeature

package final class MariaDBClient: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "io.github.future0923.QueryCraft.Driver.MariaDBClient",
        qos: .userInitiated
    )
    private let configuration: MariaDBTransportConfiguration
    private var handle: UnsafeMutablePointer<MYSQL>?
    private var cachedServerVersion: String?

    package init(configuration: MariaDBTransportConfiguration) {
        self.configuration = configuration
    }

    package func connect() async throws {
        try await runOnQueue {
            if self.handle != nil { return }
            self.handle = try self.openConnection(database: self.configuration.database)
            self.cachedServerVersion = self.string(
                from: self.handle.flatMap(mysql_get_server_info)
            )
        }
    }

    package func isConnected() async -> Bool {
        await runOnQueueReturningFalseOnError {
            self.handle != nil && mysql_ping(self.handle) == 0
        }
    }

    package func serverVersion() async -> String? {
        await runOnQueueReturningNilOnError {
            self.cachedServerVersion
        }
    }

    package func connectionID() async throws -> Int {
        try await runOnQueue {
            guard let handle = self.handle else {
                throw WorkspaceSessionError.notConnected
            }
            return Int(mysql_thread_id(handle))
        }
    }

    package func query(_ sql: String) async throws -> CDatabaseQueryResult {
        try await runOnQueue {
            guard let handle = self.handle else {
                throw WorkspaceSessionError.notConnected
            }
            return try self.query(sql, handle: handle)
        }
    }

    package func query(
        _ sql: String,
        bindings: [WorkspaceDatabaseDataCell]
    ) async throws -> CDatabaseQueryResult {
        try await runOnQueue {
            guard let handle = self.handle else {
                throw WorkspaceSessionError.notConnected
            }
            let resolvedSQL = try self.resolvePlaceholders(
                in: sql,
                bindings: bindings,
                handle: handle
            )
            return try self.query(resolvedSQL, handle: handle)
        }
    }

    package func close() async {
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
            return CDatabaseQueryResult(
                affectedRows: mysql_affected_rows(handle),
                insertID: mysql_insert_id(handle)
            )
        }
        defer { mysql_free_result(result) }

        let columnCount = Int(mysql_num_fields(result))
        let fields = mysql_fetch_fields(result)
        let columns = (0..<columnCount).map { index in
            fields.map { String(cString: $0[index].name) } ?? "column_\(index)"
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
        rows.reserveCapacity(256)

        while let rowPointer = mysql_fetch_row(result) {
            let lengths = mysql_fetch_lengths(result)
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for index in 0..<columnCount {
                guard let valuePointer = rowPointer[index] else {
                    row.append(nil)
                    continue
                }
                let length = Int(clamping: lengths?[index] ?? 0)
                let buffer = UnsafeRawBufferPointer(
                    start: valuePointer,
                    count: length
                )
                row.append(
                    String(bytes: buffer, encoding: .utf8)
                        ?? String(bytes: buffer, encoding: .isoLatin1)
                        ?? ""
                )
            }
            rows.append(row)
        }

        let fetchError = mysql_errno(handle)
        guard fetchError == 0 else {
            throw error(from: handle)
        }

        return CDatabaseQueryResult(
            columns: columns,
            columnOrigins: columnOrigins,
            rows: rows
        )
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
