import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

protocol MobileQueryExecuting: Sendable {
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult
    func preview(configuration: MariaDBTransportConfiguration, sql: String,
                 maximumRows: Int, maximumBytes: Int) async throws -> CDatabaseQueryPreview
}

extension MobileQueryExecuting {
    func preview(configuration: MariaDBTransportConfiguration, sql: String,
                 maximumRows: Int, maximumBytes: Int) async throws -> CDatabaseQueryPreview {
        let result = try await execute(configuration: configuration, sql: sql)
        return CDatabaseQueryPreview(result: result)
    }
}

struct MobileMariaDBExecutor: MobileQueryExecuting {
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        let preview = try await preview(configuration: configuration, sql: sql, maximumRows: 10_000, maximumBytes: 8_388_608)
        guard !preview.isTruncated else { throw MobileQueryError.resultTooLarge }
        return preview.result
    }

    func preview(configuration: MariaDBTransportConfiguration, sql: String,
                 maximumRows: Int, maximumBytes: Int) async throws -> CDatabaseQueryPreview {
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
            let result = try await client.queryPreview(sql, maximumRows: maximumRows, maximumBytes: maximumBytes)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}
