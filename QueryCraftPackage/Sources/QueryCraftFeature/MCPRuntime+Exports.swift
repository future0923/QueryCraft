import Foundation

extension MCPRuntime {
    func callExport(_ tool: String, args: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        let directory = store.url.deletingLastPathComponent()
        if tool != "export_query" {
            return try await MCPExportJobs.shared.control(tool, args: args, directory: directory) { record in
                let policy = try self.store.load()
                guard let profile = try await self.repository.fetch(id: record.request.connectionID),
                      try MCPExportRequest.digest(profile) == record.profileDigest else { throw MCPFailure("Export connection changed or was removed.", code: .accessDenied) }
                try policy.authorize(tool: tool, profile: profile, database: record.request.database)
                try policy.authorize(tool: "export_query", profile: profile, database: record.request.database)
                for query in record.request.queries {
                    _ = try await MCPSQLAuthorization.statements(query.sql, profile: profile, database: record.request.database, policy: policy, forceReadOnly: true)
                }
            }
        }
        guard !stopped else { throw MCPFailure("MCP runtime is shutting down.") }
        let request = try MCPExportRequest(arguments: args)
        guard let profile = try await repository.fetch(id: request.connectionID) else { throw MCPFailure("Connection not found.", code: .connectionNotFound) }
        let policy = try store.load()
        try policy.authorize(tool: tool, profile: profile, database: request.database)
        guard profile.databaseType == .mysql, await registry.isInstalled(.mysql) else { throw MCPFailure("Query export currently supports installed MySQL drivers only.", code: .unsupported) }
        for query in request.queries {
            _ = try await MCPSQLAuthorization.statements(query.sql, profile: profile, database: request.database, policy: policy, forceReadOnly: true)
        }
        return try await MCPExportJobs.shared.submit(request, profile: profile, directory: directory, credentials: credentials, registry: registry)
    }
}
