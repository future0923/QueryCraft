import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPBatchSchemaTests {
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], [false, true])
    func largeBatchIsCompactAndDetailsNeverReexecute(_ type: DatabaseType, _ delegated: Bool) async throws {
        let fixture = try await fixture(type: type)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let statements = (0..<186).map { "INSERT INTO users(id) VALUES(\($0))" }
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString), "sql": .string(statements.joined(separator: ";"))]
        let response = try await call("execute_batch", args: args, delegated: delegated, runtime: fixture.runtime)
        let summary = try #require(response.objectValue)
        #expect(summary["succeeded"] == .int(186))
        #expect(summary["failed"] == .int(0))
        #expect(summary["not_executed"] == .int(0))
        #expect(summary["results"] == nil)
        #expect(summary["transaction"] == "autocommit")
        #expect(summary["committed"] == false)
        #expect(try JSONEncoder().encode(response).count < 2000)
        let id = try #require(summary["batch_id"])
        var offset = 0
        var retrieved: [MCPJSONValue] = []
        repeat {
            let page = try await call("get_batch_results", args: ["connection_id": .string(fixture.profile.id.uuidString), "batch_id": id, "offset": .int(offset), "limit": 17], delegated: delegated, runtime: fixture.runtime)
            retrieved += try #require(page.objectValue?["results"]?.arrayValue)
            guard let next = page.objectValue?["next_offset"]?.intValue else { break }
            #expect(next > offset)
            offset = next
        } while true
        #expect(retrieved.count == 186)
        #expect(retrieved.last?.objectValue?["statement_index"] == .int(185))
        #expect(retrieved.first?.objectValue?["sql"] == .string(statements[0] + ";"))
        #expect(await fixture.driver.created.count == 1)
        let session = try #require(await fixture.driver.created.first)
        #expect(await session.statements.count == 186)
        await fixture.runtime.shutdown()
    }

    @Test func batchFailuresKeepCountsReceiptsAndPrivateErrors() async throws {
        let fixture = try await fixture(type: .mysql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString),
            "sql": "INSERT INTO users VALUES(1); INSERT INTO users VALUES('fail'); INSERT INTO users VALUES(3)"]
        let error = try #require(await #expect(throws: MCPFailure.self) {
            _ = try await fixture.runtime.call("querycraft_execute_batch", arguments: args)
        })
        let summary = try #require(error.details?.objectValue)
        #expect(summary["succeeded"] == .int(1))
        #expect(summary["failed"] == .int(1))
        #expect(summary["not_executed"] == .int(1))
        #expect(summary["completed"] == false)
        #expect(summary["details_available"] == true)
        #expect(summary["errors"]?.arrayValue?.first?.objectValue?["statement_index"] == .int(1))
        #expect(String(decoding: try JSONEncoder().encode(error.value), as: UTF8.self).contains("private-driver-secret") == false)
        let continued = try await fixture.runtime.call("querycraft_execute_batch", arguments: args.merging(["continue_on_error": true]) { _, new in new })
        #expect(continued.objectValue?["succeeded"] == .int(2))
        #expect(continued.objectValue?["failed"] == .int(1))
        #expect(continued.objectValue?["not_executed"] == .int(0))
        #expect(try await fixture.runtime.history.recent().first?.errorCode == "PARTIAL_FAILURE")
        let detailed = try await fixture.runtime.call("querycraft_execute_batch", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "sql": "SELECT 1", "result_mode": "detailed"])
        #expect(detailed.objectValue?["results"]?.arrayValue?.count == 1)
        let query = try await fixture.runtime.call("querycraft_execute_query", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "sql": "SELECT 1"])
        #expect(query.objectValue?["results"]?.arrayValue?.count == 1)
        await fixture.runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func atomicBatchReportsCommitAndRollbackTruthfully(_ fails: Bool) async throws {
        let fixture = try await fixture(type: .postgresql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString),
            "sql": .string(fails ? "INSERT INTO users VALUES(1); INSERT INTO users VALUES('fail')" : "INSERT INTO users VALUES(1)"), "use_transaction": true]
        if fails {
            let error = try #require(await #expect(throws: MCPFailure.self) { _ = try await fixture.runtime.call("querycraft_execute_batch", arguments: args) })
            #expect(error.details?.objectValue?["transaction"] == "rolled_back")
            #expect(error.details?.objectValue?["committed"] == false)
        } else {
            let result = try await fixture.runtime.call("querycraft_execute_batch", arguments: args)
            #expect(result.objectValue?["transaction"] == "committed")
            #expect(result.objectValue?["committed"] == true)
        }
        let session = try #require(await fixture.driver.created.first)
        #expect(await session.statements.first == "BEGIN")
        #expect(await session.statements.last == (fails ? "ROLLBACK" : "COMMIT"))
        await fixture.runtime.shutdown()
    }

    @Test func receiptIsScopedExpiresAndIsRemovedAtShutdown() async throws {
        let fixture = try await fixture(type: .mysql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await fixture.runtime.call("querycraft_execute_batch", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "sql": "SELECT 1"])
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString), "batch_id": try #require(result.objectValue?["batch_id"])]
        var wrongDatabase = args; wrongDatabase["database"] = "other"
        await #expect(throws: MCPFailure.self) { _ = try await fixture.runtime.call("querycraft_get_batch_results", arguments: wrongDatabase) }
        var changed = fixture.policy; changed.disabledTools.insert("execute_batch")
        try MCPPolicyStore(directory: fixture.root).save(changed)
        await #expect(throws: MCPFailure.self) { _ = try await fixture.runtime.call("querycraft_get_batch_results", arguments: args) }
        try MCPPolicyStore(directory: fixture.root).save(fixture.policy)
        await #expect(throws: MCPFailure.self) {
            _ = try await fixture.runtime.readBatchResults(args: args, profile: fixture.profile, database: "allowed", policy: fixture.policy, now: Date().addingTimeInterval(601))
        }
        #expect(await fixture.driver.created.count == 1)
        await fixture.runtime.shutdown()
        #expect(await fixture.runtime.batchResults.isEmpty)
    }

    @Test func receiptCountAndMemoryAreBounded() async throws {
        let fixture = try await fixture(type: .mysql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for _ in 0..<20 {
            _ = await fixture.runtime.batchResponse(results: [], total: 0, profile: fixture.profile, database: "allowed", policy: fixture.policy, transaction: "autocommit", completed: true, detailed: false)
        }
        #expect(await fixture.runtime.batchResults.count == 16)
        let result = await fixture.runtime.batchResponse(results: [.string(String(repeating: "x", count: 8 * 1_024 * 1_024 + 1))], total: 1, profile: fixture.profile, database: "allowed", policy: fixture.policy, transaction: "autocommit", completed: true, detailed: false)
        #expect(result.objectValue?["details_available"] == false)
        await fixture.runtime.shutdown()
    }

    @Test func receiptPagesShrinkToByteBudgetAndOversizedDetailsNeverRetry() async throws {
        let fixture = try await fixture(type: .mysql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receipt = await fixture.runtime.batchResponse(results: Array(repeating: .string(String(repeating: "x", count: 32_000)), count: 4), total: 4,
            profile: fixture.profile, database: "allowed", policy: fixture.policy, transaction: "autocommit", completed: true, detailed: false)
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString), "batch_id": try #require(receipt.objectValue?["batch_id"])]
        let page = try await fixture.runtime.call("querycraft_get_batch_results", arguments: args)
        #expect(page.objectValue?["results"]?.arrayValue?.count == 1)
        #expect(page.objectValue?["next_offset"] == .int(1))
        #expect(try JSONEncoder().encode(page).count <= 64_000)
        let huge = await fixture.runtime.batchResponse(results: [.string(String(repeating: "x", count: fixture.policy.maximumResultBytes + 1))], total: 1,
            profile: fixture.profile, database: "allowed", policy: fixture.policy, transaction: "autocommit", completed: true, detailed: false)
        let hugeID = try #require(huge.objectValue?["batch_id"])
        let error = try #require(await #expect(throws: MCPFailure.self) {
            _ = try await fixture.runtime.call("querycraft_get_batch_results", arguments: args.merging(["batch_id": hugeID]) { _, new in new })
        })
        #expect(error.code == .resultTooLarge)
        #expect(await fixture.driver.created.isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test func failedCommitAcknowledgmentNeverClaimsRollbackOrCommit() async throws {
        let fixture = try await fixture(type: .postgresql, failsCommit: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let error = try #require(await #expect(throws: MCPFailure.self) {
            _ = try await fixture.runtime.call("querycraft_execute_batch", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "sql": "INSERT INTO users VALUES(1)", "use_transaction": true])
        })
        #expect(error.details?.objectValue?["transaction"] == "unknown")
        #expect(error.details?.objectValue?["committed"] == false)
        #expect(error.details?.objectValue?["succeeded"] == .int(1))
        await fixture.runtime.shutdown()
    }

    @Test func smallestResultBudgetStillReturnsFailureSummary() async throws {
        let fixture = try await fixture(type: .mysql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = fixture.policy; policy.maximumResultBytes = 1024
        try MCPPolicyStore(directory: fixture.root).save(policy)
        let result = try await fixture.runtime.call("querycraft_execute_batch", arguments: ["connection_id": .string(fixture.profile.id.uuidString),
            "sql": .string(Array(repeating: "INSERT INTO users VALUES('fail')", count: 12).joined(separator: ";")), "continue_on_error": true])
        #expect(result.objectValue?["failed"] == .int(12))
        #expect((result.objectValue?["omitted_errors"]?.intValue ?? 0) > 0)
        #expect(try JSONEncoder().encode(result).count <= 1024)
        await fixture.runtime.shutdown()
    }

    @Test func readOnlyAtomicBatchReportsActualRollback() async throws {
        let fixture = try await fixture(type: .postgresql)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var policy = fixture.policy; policy.connections[fixture.profile.id.uuidString] = .init(mode: .readOnly)
        try MCPPolicyStore(directory: fixture.root).save(policy)
        let result = try await fixture.runtime.call("querycraft_execute_batch", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "sql": "SELECT 1", "use_transaction": true])
        #expect(result.objectValue?["transaction"] == "rolled_back")
        #expect(result.objectValue?["committed"] == false)
        let session = try #require(await fixture.driver.created.first)
        #expect(await session.statements.first == "START TRANSACTION READ ONLY")
        #expect(await session.statements.last == "ROLLBACK")
        await fixture.runtime.shutdown()
    }

    @Test(arguments: [DatabaseType.redis, .elasticsearch, .kafka])
    func nonSQLDriversDoNotOpenConnectionsForBatchDetails(_ type: DatabaseType) async throws {
        let fixture = try await fixture(type: type)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let error = try #require(await #expect(throws: MCPFailure.self) {
            _ = try await fixture.runtime.call("querycraft_get_batch_results", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "batch_id": "unused"])
        })
        #expect(error.code == .unsupported)
        #expect(await fixture.driver.created.isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test func schemaBudgetDefersWholeTablesAndExplicitSelectionKeepsOrder() async throws {
        let fixture = try await fixture(type: .mysql, objects: [.init(name: "first", kind: .table), .init(name: "second", kind: .table)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString), "tables": .array(["second", "first"]), "max_tables": 1, "format": "detailed"]
        let page = try await fixture.runtime.call("querycraft_get_schema_context", arguments: args)
        #expect(page.objectValue?["tables"]?.arrayValue?.first?.objectValue?["name"] == "second")
        let next = try await fixture.runtime.call("querycraft_get_schema_context", arguments: args.merging(["table_offset": 1]) { _, new in new })
        #expect(next.objectValue?["tables"]?.arrayValue?.first?.objectValue?["name"] == "first")
        let column = WorkspaceDatabaseColumn(name: "id", type: "int", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: "")
        let context = MCPSchemaContext.compact(profile: fixture.profile, database: "allowed", tables: [
            (.init(name: "first", kind: .table), .init(columns: [column], ddl: "")),
            (.init(name: "second", kind: .table), .init(columns: Array(repeating: column, count: 30), ddl: ""))], omittedTables: 0, budget: 256)
        #expect(context.objectValue?["returned_tables"] == .int(1))
        #expect(context.objectValue?["context"]?.stringValue?.contains("second") == false)
        #expect(context.objectValue?["incomplete_tables"] == .array([]))
        await fixture.runtime.shutdown()
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka], ["compact", "detailed"])
    func schemaPaginationAndCommentScopeFollowEveryDriver(_ type: DatabaseType, _ format: String) async throws {
        let objects = (0..<23).reversed().map { WorkspaceDatabaseObject(name: String(format: "table_%02d", $0), kind: .table) }
        let fixture = try await fixture(type: type, objects: objects)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let args: [String: MCPJSONValue] = ["connection_id": .string(fixture.profile.id.uuidString), "format": .string(format), "max_tables": 20]
        let first = try await fixture.runtime.call("querycraft_get_schema_context", arguments: args)
        #expect(first.objectValue?["returned_tables"] == .int(20))
        #expect(first.objectValue?["has_more"] == true)
        #expect(first.objectValue?["remaining_tables"] == .int(3))
        #expect(first.objectValue?["next_table_offset"] == .int(20))
        let sql = [DatabaseType.mysql, .postgresql, .doris].contains(type)
        if format == "compact" {
            let text = try #require(first.objectValue?["context"]?.stringValue)
            #expect(text.contains("table_00 [table]"))
            #expect(text.contains("verified table comment") == sql)
        } else {
            #expect(first.objectValue?["tables"]?.arrayValue?.first?.objectValue?["name"] == "table_00")
            #expect(first.objectValue?["tables"]?.arrayValue?.first?.objectValue?["comment"] == (sql ? "verified table comment" : .null))
        }
        let second = try await fixture.runtime.call("querycraft_get_schema_context", arguments: args.merging(["table_offset": 20]) { _, new in new })
        #expect(second.objectValue?["returned_tables"] == .int(3))
        #expect(second.objectValue?["has_more"] == false)
        #expect(second.objectValue?["next_table_offset"] == .null)
        let end = try await fixture.runtime.call("querycraft_get_schema_context", arguments: args.merging(["table_offset": .int(Int.max)]) { _, new in new })
        #expect(end.objectValue?["returned_tables"] == .int(0))
        #expect(end.objectValue?["has_more"] == false)
        for session in await fixture.driver.created { #expect(await session.overviewReads == (sql ? 2 : 0)) }
        await fixture.runtime.shutdown()
    }

    @Test func commentsMatchExactSchemaAndPartialTablesAreDisclosed() async throws {
        let fixture = try await fixture(type: .postgresql, objects: [.init(name: "other.users", kind: .table), .init(name: "public.users", kind: .table)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try await fixture.runtime.call("querycraft_get_schema_context", arguments: ["connection_id": .string(fixture.profile.id.uuidString), "schema": "public", "tables": .array(["users"])])
        let text = try #require(result.objectValue?["context"]?.stringValue)
        #expect(text.contains("verified table comment"))
        #expect(text.contains("wrong schema comment") == false)
        let columns = (0..<30).map { WorkspaceDatabaseColumn(name: "column_\($0)", type: "varchar(255)", collation: nil, isNullable: false, key: "", defaultValue: nil, extra: "", comment: "field comment") }
        let context = MCPSchemaContext.compact(profile: fixture.profile, database: "allowed", tables: [(.init(name: "users", kind: .table), .init(columns: columns, ddl: "", tableInformation: .init(dataSize: nil, indexSize: nil, comment: "用户\n说明")))], omittedTables: 0, budget: 256)
        #expect(context.objectValue?["context"]?.stringValue?.contains("用户 说明") == true)
        #expect(context.objectValue?["incomplete_tables"] == .array(["users"]))
        #expect(context.objectValue?["truncated"] == true)
        #expect((context.objectValue?["context"]?.stringValue?.count ?? 0) <= 256)
        await fixture.runtime.shutdown()
    }

    @Test func toolSchemasAdvertiseBoundsAndDriverApplicability() throws {
        let tool = try #require(MCPToolCatalog.definitions.first { $0.name == "get_batch_results" })
        #expect(tool.tool.annotations.readOnlyHint)
        #expect(MCPPermissionToolGroup.schema.tools.contains { $0.name == "get_batch_results" })
        for type in [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka] {
            #expect(MCPToolCatalog.driverTools(type).contains("get_batch_results") == [.mysql, .postgresql, .doris].contains(type))
        }
        #expect(throws: MCPFailure.self) { try MCPToolCatalog.validate("get_schema_context", arguments: ["connection_id": "test", "table_offset": -1]) }
        #expect(throws: MCPFailure.self) { try MCPToolCatalog.validate("get_batch_results", arguments: ["connection_id": "test", "batch_id": "test", "limit": 0]) }
    }

    private func call(_ tool: String, args: [String: MCPJSONValue], delegated: Bool, runtime: MCPRuntime) async throws -> MCPJSONValue {
        if delegated {
            return try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": try #require(args["connection_id"]), "tool": .string(tool), "arguments": .object(args)])
        }
        return try await runtime.call("querycraft_" + tool, arguments: args)
    }

    private func fixture(type: DatabaseType, objects: [WorkspaceDatabaseObject] = [.init(name: "users", kind: .table)], failsCommit: Bool = false) async throws -> (root: URL, runtime: MCPRuntime, profile: ConnectionProfile, policy: MCPPolicy, driver: MCPBatchSchemaDriver) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let profile = MCPTests().profile(type: type)
        policy.connections[profile.id.uuidString] = .init(mode: .fullAccess)
        try MCPPolicyStore(directory: root).save(policy)
        let driver = MCPBatchSchemaDriver(databaseType: type, objects: objects, failsCommit: failsCommit)
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        try await runtime.repository.insert(profile)
        let savedProfile = try #require(try await runtime.repository.fetch(id: profile.id))
        return (root, runtime, savedProfile, try MCPPolicyStore(directory: root).load(), driver)
    }
}

private actor MCPBatchSchemaDriver: DatabaseDriver {
    nonisolated let databaseType: DatabaseType
    let objects: [WorkspaceDatabaseObject]
    let failsCommit: Bool
    var created: [MCPBatchSchemaSession] = []
    init(databaseType: DatabaseType, objects: [WorkspaceDatabaseObject], failsCommit: Bool) { self.databaseType = databaseType; self.objects = objects; self.failsCommit = failsCommit }
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession {
        let session = MCPBatchSchemaSession(objects: objects, failsCommit: failsCommit); created.append(session); return session
    }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}

private actor MCPBatchSchemaSession: WorkspaceSession, WorkspaceSQLObjectOverviewProviding {
    let objects: [WorkspaceDatabaseObject]
    let failsCommit: Bool
    var statements: [String] = []
    var overviewReads = 0
    init(objects: [WorkspaceDatabaseObject], failsCommit: Bool) { self.objects = objects; self.failsCommit = failsCommit }
    func connect() async throws {}
    func close() async {}
    func fetchDatabases() async throws -> [String] { ["allowed"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { objects }
    func fetchSQLObjectOverview(in database: String) async throws -> [WorkspaceSQLObjectOverviewEntry] {
        overviewReads += 1
        return objects.map { .init(object: $0, comment: $0.name.hasPrefix("other.") ? "wrong schema comment" : "verified table comment") }
    }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { .init(columns: [], ddl: "CREATE TABLE fixture(id INT)") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw MCPFailure("unused") }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func executeReadOnlyQuery(_ sql: String, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult { .init(columns: [], rowCount: 0) }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        statements.append(sql)
        if sql.contains("'fail'") || (failsCommit && sql == "COMMIT") { throw NSError(domain: "private-driver-secret", code: 1) }
        return .init(columns: [], rowCount: 1)
    }
}
