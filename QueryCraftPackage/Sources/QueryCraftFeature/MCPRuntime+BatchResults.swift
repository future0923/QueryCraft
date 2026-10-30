import Foundation

extension MCPRuntime {
    struct BatchResultEntry: Sendable {
        let profile: ConnectionProfile
        let database: String?
        let policy: MCPPolicy
        let results: [MCPJSONValue]
        let stored: Date
        let bytes: Int
    }

    func pruneBatchResults(now: Date = Date()) {
        batchResults = batchResults.filter { now.timeIntervalSince($0.value.stored) < 600 }
        while batchResults.count > 16 || batchResults.values.reduce(0, { $0 + $1.bytes }) > 32 * 1_024 * 1_024 {
            guard let oldest = batchResults.min(by: { $0.value.stored < $1.value.stored })?.key else { break }
            batchResults.removeValue(forKey: oldest)
        }
    }

    /// Receipts are ephemeral, bounded and never persisted to call history. Retrieving one never executes SQL.
    func batchResponse(results: [MCPJSONValue], total: Int, profile: ConnectionProfile, database: String?, policy: MCPPolicy,
                       transaction: String, completed: Bool, detailed: Bool) -> MCPJSONValue {
        pruneBatchResults()
        let failures = results.filter { $0.objectValue?["error"] != nil }
        let succeeded = results.count - failures.count
        let bytes = (try? JSONEncoder().encode(MCPJSONValue.array(results)).count) ?? Int.max
        var id: String?
        if bytes <= 8 * 1_024 * 1_024, !stopped {
            let key = UUID().uuidString
            batchResults[key] = .init(profile: profile, database: database, policy: policy, results: results, stored: Date(), bytes: bytes)
            pruneBatchResults()
            if batchResults[key] != nil { id = key }
        }
        var errors: [MCPJSONValue] = []
        for failure in failures.prefix(10) {
            guard let fields = failure.objectValue else { continue }
            let item = MCPJSONValue.object(["statement_index": fields["statement_index"] ?? .null,
                "sql_preview": .string(String((fields["sql"]?.stringValue ?? "").prefix(200))), "error": fields["error"] ?? .null])
            let candidate = errors + [item]
            guard ((try? JSONEncoder().encode(MCPJSONValue.array(candidate)).count) ?? Int.max) <= policy.maximumResultBytes / 2 else { break }
            errors = candidate
        }
        var value: [String: MCPJSONValue] = ["total_statements": .int(total), "succeeded": .int(succeeded), "failed": .int(failures.count),
            "not_executed": .int(total - results.count), "completed": .bool(completed), "errors": .array(errors),
            "omitted_errors": .int(failures.count - errors.count), "transaction": .string(transaction),
            "committed": .bool(transaction == "committed"), "batch_id": id.map(MCPJSONValue.string) ?? .null,
            "details_available": .bool(id != nil), "details_expires_in_seconds": .int(id == nil ? 0 : 600),
            "next_step": .string("Counts describe statement execution, not durable writes; inspect transaction status. Read get_batch_results with batch_id for bounded details. Details expire or may be evicted; never repeat writes to retrieve output.")]
        if detailed {
            value["results"] = .array(results)
            if ((try? JSONEncoder().encode(MCPJSONValue.object(value)).count) ?? Int.max) > policy.maximumResultBytes {
                value.removeValue(forKey: "results")
                value["inline_details_truncated"] = true
            }
        }
        while !errors.isEmpty, ((try? JSONEncoder().encode(MCPJSONValue.object(value)).count) ?? Int.max) > policy.maximumResultBytes {
            errors.removeLast()
            value["errors"] = .array(errors)
            value["omitted_errors"] = .int(failures.count - errors.count)
        }
        return .object(value)
    }

    func readBatchResults(args: [String: MCPJSONValue], profile: ConnectionProfile, database: String?, policy: MCPPolicy, now: Date = Date()) throws -> MCPJSONValue {
        guard [.mysql, .postgresql, .doris].contains(profile.databaseType) else {
            throw MCPFailure("Batch SQL details are unavailable on this driver.", code: .unsupported)
        }
        pruneBatchResults(now: now)
        let id = try args.requiredString("batch_id")
        guard let entry = batchResults[id] else {
            throw MCPFailure("Batch details expired, were evicted, or belong to another runtime. Never reexecute writes to retrieve output.", code: .objectNotFound,
                             recovery: "Inspect the original summary and database state. Batch details are available only in the executing runtime for up to 10 minutes.")
        }
        guard entry.profile == profile, entry.database == database, entry.policy == policy else {
            throw MCPFailure("Batch details require the original saved connection, database and unchanged MCP permissions.", code: .accessDenied)
        }
        try policy.authorize(tool: "execute_batch", profile: profile, database: database)
        let offset = min(args.integer("offset", default: 0), entry.results.count)
        let limit = min(100, args.integer("limit", default: 20))
        var page: [MCPJSONValue] = []
        func response(_ page: [MCPJSONValue]) -> MCPJSONValue {
            let end = offset + page.count
            return .object(["batch_id": .string(id), "results": .array(page), "total_results": .int(entry.results.count),
                "offset": .int(offset), "has_more": .bool(end < entry.results.count), "next_offset": end < entry.results.count ? .int(end) : .null])
        }
        for result in entry.results.dropFirst(offset).prefix(limit) {
            let candidate = page + [result]
            let bytes = try JSONEncoder().encode(response(candidate)).count
            guard bytes <= policy.maximumResultBytes, page.isEmpty || bytes <= 64_000 else { break }
            page = candidate
        }
        guard !page.isEmpty || offset == entry.results.count else {
            throw MCPFailure("This statement detail exceeds the result limit. The batch was already executed; do not repeat writes.", code: .resultTooLarge)
        }
        return response(page)
    }
}
