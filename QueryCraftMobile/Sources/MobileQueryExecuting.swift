import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

protocol MobileQueryExecuting: Sendable {
    func batch(configuration: MobileSQLConfiguration, statements: [SQLExecutionStatement],
               receive: @escaping @Sendable (MobileQueryBatchEvent) async throws -> Void) async throws
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult
    func preview(configuration: MobileSQLConfiguration, sql: String,
                 maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview
}

extension MobileQueryExecuting {
    func batch(configuration: MobileSQLConfiguration, statements: [SQLExecutionStatement],
               receive: @escaping @Sendable (MobileQueryBatchEvent) async throws -> Void) async throws {
        try MobileQueryBatchLimits.validate(statements)
        for statement in statements { try MobileSQLReadPolicy.validate(statement.sql) }
        var remaining = MobileQueryBatchLimits.maximumBytes
        try await SQLExecutionBatchRunner.run(statements) { statement in
            guard remaining > 0 else { throw MobileQueryBatchError.resultBudget }
            try await receive(.started(statement.index))
            let result = try await preview(configuration: configuration, sql: statement.sql,
                maximumRows: 500, maximumBytes: min(4_194_304, remaining))
            try Task.checkCancellation()
            remaining -= MobileQueryBatchLimits.retainedBytes(result)
            try await receive(.completed(statement.index, result))
            if result.isTruncated, statement.index != statements.last?.index { throw MobileQueryBatchError.truncatedSession }
        }
    }

    func preview(configuration: MobileSQLConfiguration, sql: String,
                 maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview {
        let result = try await execute(configuration: configuration, sql: sql)
        return MobileSQLPreview(result: result)
    }
}

struct MobileMariaDBExecutor: MobileQueryExecuting {
    func batch(configuration: MobileSQLConfiguration, statements: [SQLExecutionStatement],
               receive: @escaping @Sendable (MobileQueryBatchEvent) async throws -> Void) async throws {
        try MobileQueryBatchLimits.validate(statements)
        guard configuration.tlsMode == .disabled || configuration.tlsMode == .required else { throw MobileQueryError.verifiedTLSUnavailable }
        let client = MariaDBClient(configuration: configuration)
        do {
            try Task.checkCancellation(); try await client.connect()
            let mode = try await client.query("SELECT @@SESSION.sql_mode")
            guard let sqlMode = mode.rows.first?.first ?? nil else { throw MobileQueryError.invalidServerMetadata }
            let backslashEscapes = !sqlMode.uppercased().split(separator: ",").contains("NO_BACKSLASH_ESCAPES")
            // Validate the entire captured plan before executing even its first query.
            for statement in statements { try MobileSQLReadPolicy.validate(statement.sql, backslashEscapes: backslashEscapes) }
            try Task.checkCancellation()
            _ = try await client.query("SET SESSION TRANSACTION READ ONLY")
            _ = try await client.query("START TRANSACTION READ ONLY")
            var remaining = MobileQueryBatchLimits.maximumBytes
            try await SQLExecutionBatchRunner.run(statements) { statement in
                guard remaining > 0 else { throw MobileQueryBatchError.resultBudget }
                try await receive(.started(statement.index))
                try Task.checkCancellation()
                let preview = try await client.mobilePreview(statement.sql, maximumRows: 500, maximumBytes: min(4_194_304, remaining))
                try Task.checkCancellation()
                remaining -= MobileQueryBatchLimits.retainedBytes(preview)
                try await receive(.completed(statement.index, preview))
                // Truncation deliberately closes the unbuffered connection. Never
                // silently reconnect and pretend session state was preserved.
                if preview.isTruncated, statement.index != statements.last?.index { throw MobileQueryBatchError.truncatedSession }
            }
            await client.close()
        } catch { await client.close(); throw error }
    }

    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        let preview = try await preview(configuration: configuration, sql: sql, maximumRows: 10_000, maximumBytes: 8_388_608)
        guard !preview.isTruncated else { throw MobileQueryError.resultTooLarge }
        return preview.result
    }

    func preview(configuration: MobileSQLConfiguration, sql: String,
                 maximumRows: Int, maximumBytes: Int) async throws -> MobileSQLPreview {
        // Connector/C 3.4 treats loopback certificates specially. Do not expose a
        // verified mode until CA provisioning and strict verification are implemented.
        guard configuration.tlsMode == .disabled || configuration.tlsMode == .required else {
            throw MobileQueryError.verifiedTLSUnavailable
        }
        guard sql.utf8.count <= 262_144 else { throw MobileQueryError.readOnlySQLRequired }
        // A fresh connection per execution isolates cancellation and edited endpoints.
        // Multi-execution transactions are deliberately outside this first proof.
        let client = MariaDBClient(configuration: configuration)
        do {
            try Task.checkCancellation()
            try await client.connect()
            try Task.checkCancellation()
            let mode = try await client.query("SELECT @@SESSION.sql_mode")
            guard let sqlMode = mode.rows.first?.first ?? nil else { throw MobileQueryError.invalidServerMetadata }
            try MobileSQLReadPolicy.validate(sql,
                backslashEscapes: !sqlMode.uppercased().split(separator: ",").contains("NO_BACKSLASH_ESCAPES"))
            _ = try await client.query("SET SESSION TRANSACTION READ ONLY")
            _ = try await client.query("START TRANSACTION READ ONLY")
            let result = try await client.mobilePreview(sql, maximumRows: maximumRows, maximumBytes: maximumBytes)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}
