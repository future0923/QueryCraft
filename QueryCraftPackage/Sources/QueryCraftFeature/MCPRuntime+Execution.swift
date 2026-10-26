import Foundation

extension MCPRuntime {
    func execute(_ tool: String, args: [String: MCPJSONValue], profile: ConnectionProfile, database: String?,
                 connection: any WorkspaceSession, policy: MCPPolicy, inTransaction: Bool) async throws -> MCPJSONValue {
        try await withThrowingTaskGroup(of: MCPJSONValue.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await self.perform(tool, args: args, profile: profile, database: database, connection: connection,
                                           policy: policy, inTransaction: inTransaction)
                } onCancel: { Task { await connection.close() } }
            }
            if policy.effectiveQueryTimeoutSeconds > 0 {
                group.addTask {
                    try await Task.sleep(for: .seconds(policy.effectiveQueryTimeoutSeconds))
                    throw MCPFailure("MCP operation timed out. Writes may be unconfirmed; do not automatically retry.", code: .timeout)
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func perform(_ tool: String, args: [String: MCPJSONValue], profile: ConnectionProfile, database: String?,
                         connection: any WorkspaceSession, policy: MCPPolicy, inTransaction: Bool) async throws -> MCPJSONValue {
        let accessTarget = profile.databaseType == .kafka ? args.string("topic")
            : profile.databaseType == .elasticsearch ? args.string("path").flatMap(MCPRequestAuthorization.index) : database
        let mode = policy.effectiveMode(profile, database: accessTarget)
        let limit = min(policy.maximumRows, max(1, args.integer("max_rows", default: 100)))
        let buffer = MCPResultBuffer(limit: limit, byteLimit: policy.maximumResultBytes,
                                     cellOffset: args.integer("cell_char_offset", default: 0), cellLimit: args.integer("cell_char_limit", default: 200))
        switch tool {
        case "list_databases":
            if [.kafka, .elasticsearch].contains(profile.databaseType) {
                return .array(try await connection.fetchObjects(in: database ?? "").filter { policy.permitsObject($0, profile: profile, schema: args.string("schema")) }.prefix(1000).map { .string($0.name) })
            }
            let allowed = policy.connectionRule(profile).allowedDatabases
            return .array(try await connection.fetchDatabases().filter { allowed == nil || allowed!.contains($0) }.map(MCPJSONValue.string))
        case "list_tables":
            let objects = try await connection.fetchObjects(in: database ?? "").filter { policy.permitsObject($0, profile: profile, schema: args.string("schema")) }
            return .array(objects.prefix(1000).map { .object(["name": .string($0.name), "kind": .string($0.kind.rawValue)]) })
        case "describe_table", "get_schema_context":
            let objects = try await connection.fetchObjects(in: database ?? "").filter { policy.permitsObject($0, profile: profile, schema: args.string("schema")) }
            let supplied = args["tables"]?.arrayValue?.compactMap(\.stringValue)
            let requested = tool == "describe_table" ? [try args.requiredString("table")]
                : ((supplied?.isEmpty == false) ? supplied! : objects.map(\.name))
            let maximumTables = tool == "describe_table" ? 1 : min(20, max(1, args.integer("max_tables", default: 8)))
            var details: [(WorkspaceDatabaseObject, WorkspaceDatabaseObjectDetails)] = []
            for name in requested.prefix(maximumTables) {
                try Task.checkCancellation()
                guard let object = objects.first(where: { $0.name == name || (args.string("schema") != nil && $0.nameWithinSchema == name) }) else {
                    throw MCPFailure("Object not found in the selected database/schema or outside the authorized scope.", code: .objectNotFound)
                }
                details.append((object, try await connection.fetchDetails(for: object, in: database ?? "")))
            }
            if tool == "get_schema_context", args.string("format") != "detailed" {
                return MCPSchemaContext.compact(profile: profile, database: database, tables: details,
                    omittedTables: max(0, requested.count - details.count), budget: min(policy.maximumResultBytes / 4, args.integer("max_chars", default: 16_000)))
            }
            let values: [MCPJSONValue] = details.map { object, detail in
                .object(["name": .string(object.name), "ddl": .string(detail.ddl), "columns": .array(detail.columns.map {
                    .object(["name": .string($0.name), "type": .string($0.type), "nullable": .bool($0.isNullable),
                             "comment": .string($0.comment), "key": .string($0.key), "default": $0.defaultValue.map(MCPJSONValue.string) ?? .null])
                })])
            }
            if tool == "describe_table" { return .array(values) }
            return .object(["tables": .array(values), "truncated": .bool(requested.count > details.count)])
        case "execute_query", "execute_batch", "execute_and_show":
            let statements = try await MCPSQLAuthorization.statements(try args.requiredString("sql"), profile: profile, database: database, policy: policy)
            if mode == .fullAccess, !args.flag("confirm_high_risk"), statements.contains(where: { statement in
                switch statement.kind {
                case .ddl, .control, .unknown: true
                case .update, .delete: !MCPSQLAuthorization.hasBoundedFilter(statement.sql)
                default: false
                }
            }) { throw MCPFailure("This operation requires confirm_high_risk=true under full access.", code: .confirmationRequired) }
            let changesSchema = statements.contains { if case .ddl = $0.kind { return true }; return false }
            // Invalidate before execution and on every exit, including partial/unknown outcomes.
            if changesSchema { invalidateMetadata(for: profile.id) }
            defer { if changesSchema { invalidateMetadata(for: profile.id) } }
            let atomic = args.flag("use_transaction")
            guard !atomic || (!inTransaction && args.string("session_id") == nil && !args.flag("continue_on_error")
                && [.mysql, .postgresql].contains(profile.databaseType)) else { throw MCPFailure("Atomic batches require an independent SQL connection and stop-on-error.") }
            if (atomic || inTransaction) && statements.contains(where: { if case .ddl = $0.kind { return true }; return false }) {
                throw MCPFailure("This driver cannot track DDL inside MCP transactions. Execute it separately in autocommit mode.")
            }
            let readOnlyTransaction = mode == .readOnly && !inTransaction && [.mysql, .postgresql].contains(profile.databaseType)
            let ownsTransaction = atomic || readOnlyTransaction
            if let schema = args.string("schema") { try await connection.applyQueryContext(.init(databaseName: database ?? "", schemaName: schema)) }
            if ownsTransaction { _ = try await connection.executeStatement(readOnlyTransaction ? "START TRANSACTION READ ONLY" : "BEGIN", kind: .transaction(.begin), database: database, onBatch: { _ in }) }
            var results: [MCPJSONValue] = []
            do {
                for statement in statements {
                    try Task.checkCancellation()
                    let current = try store.load()
                    try current.authorize(tool: tool, profile: profile, database: database)
                    _ = try await MCPSQLAuthorization.statements(statement.sql, profile: profile, database: database, policy: current)
                    let rows = MCPResultBuffer(limit: limit, byteLimit: max(1024, policy.maximumResultBytes / statements.count),
                                               cellOffset: args.integer("cell_char_offset", default: 0), cellLimit: args.integer("cell_char_limit", default: 200))
                    do {
                        let started = Date()
                        let result = try await connection.executeStatement(statement.sql, kind: statement.kind, database: database,
                            maximumRows: statement.kind == .read ? limit + 1 : nil, onBatch: { try await rows.append($0) })
                        results.append(.object(["sql": .string(statement.sql), "elapsed_seconds": .double(Date().timeIntervalSince(started)), "result": await rows.value(hasMore: result.rowCount > limit),
                                                "affected_or_returned_rows": .int(result.rowCount),
                                                "transaction": .string(inTransaction || atomic ? "active" : "autocommit")]))
                    } catch {
                        guard args.flag("continue_on_error"), !ownsTransaction, !inTransaction, !Task.isCancelled else { throw error }
                        results.append(.object(["sql": .string(statement.sql), "error": .string("Statement failed. No automatic retry was performed.")]))
                    }
                }
                if readOnlyTransaction {
                    _ = try await connection.executeStatement("ROLLBACK", kind: .transaction(.rollback), database: database, onBatch: { _ in })
                } else if atomic {
                    let current = try store.load()
                    try current.authorize(tool: tool, profile: profile, database: database)
                    guard current.effectiveMode(profile, database: database) == mode else { throw MCPFailure("Permissions changed; the batch was rolled back.", code: .accessDenied) }
                    _ = try await MCPSQLAuthorization.statements(try args.requiredString("sql"), profile: profile, database: database, policy: current)
                    _ = try await connection.executeStatement("COMMIT", kind: .transaction(.commit), database: database, onBatch: { _ in })
                }
            } catch {
                if ownsTransaction { _ = try? await connection.executeStatement("ROLLBACK", kind: .transaction(.rollback), database: database, onBatch: { _ in }) }
                throw error
            }
            return .object(["results": .array(results), "committed": .bool(atomic && !readOnlyTransaction)])
        case "list_routines", "get_routine_source":
            guard [.mysql, .postgresql].contains(profile.databaseType) else { throw MCPFailure("Routine metadata is unavailable on this driver.") }
            let schema = args.string("schema") ?? (profile.databaseType == .postgresql ? "public" : database ?? "")
            // Hex/string escaping is driver-specific; reject control bytes and escape both SQL quoting forms.
            func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'" }
            var sql = "SELECT routine_schema, routine_name, specific_name, routine_type, routine_definition FROM information_schema.routines WHERE routine_schema = \(literal(schema))"
            if let kind = args.string("kind") {
                guard ["FUNCTION", "PROCEDURE"].contains(kind.uppercased()) else { throw MCPFailure("Routine kind must be FUNCTION or PROCEDURE.") }
                sql += " AND routine_type = \(literal(kind.uppercased()))"
            }
            if tool == "get_routine_source" { sql += " AND routine_name = \(literal(try args.requiredString("name")))" }
            if let allowed = policy.connectionRule(profile).allowedDatabases, profile.databaseType == .mysql, !allowed.contains(schema) { throw MCPFailure("Routine schema is not authorized.", code: .accessDenied) }
            _ = try await connection.executeReadOnlyQuery(sql, database: database, maximumRows: limit, onBatch: { try await buffer.append($0) })
            return await buffer.value()
        case "execute_redis_command":
            guard let redis = connection as? any RedisWorkspaceSession,
                  let arguments = args["arguments"]?.arrayValue?.compactMap(\.stringValue), !arguments.isEmpty else { throw MCPFailure("A Redis connection and arguments array are required.") }
            let name = arguments[0].uppercased()
            let reads: Set<String> = ["GET", "MGET", "TYPE", "TTL", "PTTL", "EXISTS", "SCAN", "HGET", "HMGET", "HSCAN", "HLEN", "LLEN", "LRANGE", "SCARD", "SSCAN", "SISMEMBER", "ZCARD", "ZRANGE", "ZSCAN", "XRANGE", "XLEN", "PING", "DBSIZE"]
            let writes: Set<String> = ["SET", "SETEX", "PSETEX", "SETNX", "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "PERSIST", "HSET", "HDEL", "LPUSH", "RPUSH", "LPOP", "RPOP", "SADD", "SREM", "ZADD", "ZREM", "INCR", "DECR", "XADD"]
            let destructive = ["FLUSHDB", "FLUSHALL"].contains(name)
            if destructive {
                guard mode == .fullAccess, args.flag("confirm_high_risk"),
                      name == "FLUSHDB" || policy.connectionRule(profile).allowedDatabases == nil else {
                    throw MCPFailure("Redis flush requires full access, explicit confirmation and an authorized database scope.")
                }
            }
            guard !["SELECT", "AUTH", "HELLO", "QUIT", "MONITOR", "SUBSCRIBE", "PSUBSCRIBE", "MULTI", "EXEC", "WATCH", "DISCARD", "BLPOP", "BRPOP"].contains(name),
                  reads.contains(name) || (mode != .readOnly && writes.contains(name)) || destructive else {
                throw MCPFailure("Redis command is unavailable under the current MCP policy.", code: .accessDenied)
            }
            guard let db = Int(database ?? "0"), db >= 0 else { throw MCPFailure("Invalid Redis logical database.") }
            let result = try await redis.executeRedisCommand(.init(source: arguments.joined(separator: " "), arguments: arguments), databaseIndex: db)
            return .object(["reply": redisValue(result.reply), "truncated": .bool(redisTruncated(result.reply))])
        case "execute_request":
            invalidateMetadata(for: profile.id)
            defer { invalidateMetadata(for: profile.id) }
            guard let rest = connection as? any WorkspaceRequestExecutingSession,
                  let method = WorkspaceRequestMethod(rawValue: try args.requiredString("method").uppercased()) else { throw MCPFailure("An Elasticsearch connection and valid method are required.") }
            let path = try args.requiredString("path")
            let request = WorkspaceRequest(method: method, path: path, body: args.string("body").map { Data($0.utf8) })
            try MCPRequestAuthorization.validate(request, allowed: policy.connectionRule(profile).allowedDatabases)
            if mode == .dataWrite && WorkspaceRequestClassifier.requiresDangerousConfirmation(request) {
                throw MCPFailure("This Elasticsearch operation requires full access.", code: .accessDenied)
            }
            if mode == .fullAccess, WorkspaceRequestClassifier.requiresDangerousConfirmation(request), !args.flag("confirm_high_risk") {
                throw MCPFailure("This Elasticsearch operation requires confirm_high_risk=true.", code: .confirmationRequired)
            }
            let result = try await rest.executeRequest(request, policy: mode == .readOnly ? .readOnly : .writesAllowed)
            guard result.body.count <= policy.maximumResultBytes else { throw MCPFailure("REST response exceeds the result limit. Narrow the request.", code: .resultTooLarge) }
            return .object(["status": .int(result.statusCode), "body": .string(String(decoding: result.body, as: UTF8.self))])
        case "peek_messages":
            guard let kafka = connection as? any WorkspaceKafkaReading else { throw MCPFailure("Kafka reading is unavailable. Update the Kafka driver.") }
            let topic = try args.requiredString("topic")
            try authorizeTopic(topic, profile: profile, policy: policy)
            let partition = args["partition"]?.intValue.flatMap(Int32.init(exactly:))
            let request = WorkspaceKafkaReadRequest(partition: partition, start: args["offset"]?.intValue.map { .offset(Int64($0)) } ?? .earliest)
            guard request.isValid else { throw MCPFailure("Invalid Kafka partition/offset.") }
            try await kafka.prepareReading(topic: topic, request: request)
            let objects = try await connection.fetchObjects(in: database ?? "").filter { policy.permitsObject($0, profile: profile, schema: args.string("schema")) }
            guard let object = objects.first(where: { $0.name == topic }) else { throw MCPFailure("Topic not found.") }
            let result = try await connection.fetchDataPage(for: object, in: database ?? "", offset: 0, limit: limit,
                sort: .none, filter: .empty, onBatch: { batch in try? await buffer.append(batch) })
            return await buffer.value(hasMore: result.hasNextPage)
        case "send_message":
            invalidateMetadata(for: profile.id)
            defer { invalidateMetadata(for: profile.id) }
            guard mode != .readOnly, let kafka = connection as? any WorkspaceKafkaProducing else { throw MCPFailure("Kafka produce requires write permission and a compatible driver.") }
            let topic = try args.requiredString("topic"); try authorizeTopic(topic, profile: profile, policy: policy)
            let request = WorkspaceKafkaProduceRequest(topic: topic, partition: args["partition"]?.intValue.flatMap(Int32.init(exactly:)),
                key: args.string("key").map { Data($0.utf8) }, value: Data(try args.requiredString("value").utf8))
            try request.validate()
            let receipt = try await kafka.produce(request)
            return .object(["partition": .int(Int(receipt.partition)), "offset": receipt.offset.map { .string(String($0)) } ?? .null, "confirmed": true])
        case "consumer_groups":
            guard let kafka = connection as? any WorkspaceKafkaConsumerGroupProviding else { throw MCPFailure("Kafka consumer groups are unavailable on this driver.") }
            let topic = try args.requiredString("topic"); try authorizeTopic(topic, profile: profile, policy: policy)
            var values: [MCPJSONValue] = []
            for group in try await kafka.fetchConsumerGroups().prefix(100) {
                let offsets = try await kafka.fetchConsumerOffsets(groupID: group.id, topic: topic)
                if policy.connectionRule(profile).allowedDatabases != nil {
                    if let membership = connection as? any WorkspaceKafkaGroupTopicMembershipProviding {
                        guard try await membership.fetchGroupTopicMembership(groupID: group.id, topic: topic) == .related else { continue }
                    } else if !offsets.contains(where: { $0.committedOffset != nil }) { continue }
                }
                values.append(.object(["id": .string(group.id), "state": .string(group.state), "partitions": .array(offsets.map {
                    .object(["partition": .int(Int($0.partition)), "lag": $0.lag.map { .string(String($0)) } ?? .null])
                })]))
            }
            return .array(values)
        default: throw MCPFailure("Tool is not supported by this driver.")
        }
    }

    private func authorizeTopic(_ topic: String, profile: ConnectionProfile, policy: MCPPolicy) throws {
        if let allowed = policy.connectionRule(profile).allowedDatabases, !allowed.contains(topic) {
            throw MCPFailure("Topic is outside the authorized scope.", code: .accessDenied)
        }
    }
    private func redisTruncated(_ value: RedisReplyValue) -> Bool {
        switch value {
        case .array(let a), .set(let a): a.count > 1000 || a.prefix(1000).contains(where: redisTruncated)
        case .map(let a): a.count > 1000 || a.prefix(1000).contains { redisTruncated($0.key) || redisTruncated($0.value) }
        default: false
        }
    }
    private func redisValue(_ value: RedisReplyValue) -> MCPJSONValue {
        switch value {
        case .null: .null
        case .simpleString(let s), .bulkString(let s): .string(s)
        case .integer(let n): .string(String(n))
        case .double(let n): .string(String(n))
        case .boolean(let b): .bool(b)
        case .array(let a), .set(let a): .array(a.prefix(1000).map(redisValue))
        case .map(let a): .array(a.prefix(1000).map { .object(["key": redisValue($0.key), "value": redisValue($0.value)]) })
        case .error(let s): .object(["error": .string(s)])
        }
    }
}
