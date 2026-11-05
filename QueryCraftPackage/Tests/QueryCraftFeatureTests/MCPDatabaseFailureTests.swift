import Foundation
import Security
import Testing
@testable import QueryCraftFeature

struct MCPDatabaseFailureTests {
    @Test(arguments: [
        (1049, MCPFailureCode.databaseNotFound), (1044, .databaseAccessDenied),
        (1045, .authenticationFailed), (1142, .databaseAccessDenied),
        (2003, .connectionFailed), (2013, .connectionFailed), (2026, .tlsFailed),
        (1064, .databaseError), (999999, .databaseError)
    ])
    func mariaDBClassifiesNativeCodesWithoutLeakingMessages(_ item: (Int, MCPFailureCode)) throws {
        let error = NSError(domain: "io.querycraft.driver.mariadb", code: item.0,
            userInfo: [NSLocalizedDescriptionKey: "password=fixture-secret SELECT sensitive_value", "sql_state": "HY000", "sql": "fixture-secret"])
        for type in [DatabaseType.mysql, .doris] {
            let failure = MCPFailure.databaseOperation(error, phase: .connect, type: type)
            #expect(failure.code == item.1)
            #expect(failure.details?.objectValue?["native_code"] == .int(item.0))
            #expect(failure.details?.objectValue?["sql_state"] == "HY000")
            #expect(failure.details?.objectValue?["phase"] == "connect")
            #expect(failure.details?.objectValue?["database_type"] == .string(type.rawValue))
            let json = String(decoding: try JSONEncoder().encode(failure.value), as: UTF8.self)
            #expect(json.contains("fixture-secret") == false)
            #expect(json.contains("sensitive_value") == false)
            #expect(failure.value.objectValue?["error"]?.objectValue?["automatic_retry"] == false)
        }
    }

    @Test(arguments: [("3D000", MCPFailureCode.databaseNotFound), ("42501", .databaseAccessDenied),
        ("28P01", .authenticationFailed), ("28000", .authenticationFailed), ("08006", .connectionFailed), ("42601", .databaseError)])
    func postgresUsesSQLSTATE(_ item: (String, MCPFailureCode)) {
        let failure = MCPFailure.normalized(NSError(domain: "io.querycraft.driver.postgresql", code: 0, userInfo: ["sql_state": item.0]))
        #expect(failure.code == item.1)
        #expect(failure.details?.objectValue?["sql_state"] == .string(item.0))
        #expect(failure.details?.objectValue?["native_code"] == nil)
    }

    @Test(arguments: ["secret-value", "abcde", "42\n01", "秘密000", ""]) func invalidSQLSTATEIsNeverExported(_ value: String) {
        let failure = MCPFailure.normalized(NSError(domain: "io.querycraft.driver.postgresql", code: 0, userInfo: ["sql_state": value]))
        #expect(failure.code == .databaseError)
        #expect(failure.details?.objectValue?["sql_state"] == nil)
    }

    @Test(arguments: [(401, MCPFailureCode.authenticationFailed), (403, .databaseAccessDenied), (404, .databaseError),
        (429, .databaseError), (-1, .connectionFailed), (-2, .tlsFailed), (-3, .timeout)])
    func elasticsearchUsesTypedHTTPAndTransportErrors(_ item: (Int, MCPFailureCode)) {
        let failure = MCPFailure.normalized(NSError(domain: "io.querycraft.driver.elasticsearch", code: item.0))
        #expect(failure.code == item.1)
        #expect(failure.details?.objectValue?["http_status"] == (item.0 > 0 ? .int(item.0) : nil))
        // A 404 can refer to a document or endpoint; it must not claim the database is missing.
    }

    @Test(arguments: [("NOAUTH", MCPFailureCode.authenticationFailed), ("WRONGPASS", .authenticationFailed),
        ("NOPERM", .databaseAccessDenied), ("WRONGTYPE", .databaseError), ("fixture-secret", .databaseError)])
    func redisExportsOnlyAllowlistedRESPCodes(_ item: (String, MCPFailureCode)) throws {
        let failure = MCPFailure.normalized(NSError(domain: "io.querycraft.driver.redis", code: 0, userInfo: ["response_code": item.0]))
        #expect(failure.code == item.1)
        #expect(String(decoding: try JSONEncoder().encode(failure.value), as: UTF8.self).contains("fixture-secret") == false)
    }

    @Test(arguments: [(58, MCPFailureCode.authenticationFailed), (29, .databaseAccessDenied),
        (30, .databaseAccessDenied), (13, .connectionFailed), (3, .databaseError), (Int.min, .databaseError)])
    func kafkaClassifiesOnlyRetainedProtocolCodes(_ item: (Int, MCPFailureCode)) {
        let failure = MCPFailure.normalized(NSError(domain: "io.querycraft.driver.kafka", code: item.0))
        #expect(failure.code == item.1)
        #expect(failure.details?.objectValue?["native_code"] == (item.0 == Int.min ? nil : .int(item.0)))
    }

    @Test func legacyErrorsCancellationCredentialsAndPolicyKeepTheirMeaning() throws {
        let raw = NSError(domain: "legacy.driver", code: 1049, userInfo: [NSLocalizedDescriptionKey: "Unknown database fixture-secret"])
        let legacy = MCPFailure.normalized(raw)
        #expect(legacy.code == .driverFailure)
        #expect(legacy.details == nil)
        #expect(legacy.message.contains("fixture-secret") == false)
        #expect(MCPFailure.normalized(CancellationError()).code == .cancelled)
        #expect(MCPFailure.normalized(URLError(.cancelled)).code == .cancelled)
        #expect(MCPFailure.normalized(KeychainError(status: errSecAuthFailed)).code == .credentialDenied)
        let policy = MCPFailure("Denied by MCP policy", code: .accessDenied, details: .object(["missing_grants": .array(["connection"])]))
        let wrapped = MCPFailure.databaseOperation(policy, phase: .execution, type: .mysql)
        #expect(wrapped.code == .accessDenied)
        #expect(wrapped.details?.objectValue?["missing_grants"] == .array(["connection"]))
        #expect(MCPFailure.normalized(DatabaseDriverError.notInstalled(.mysql)).code == .driverUnavailable)
        let inner = MCPFailure.databaseOperation(raw, phase: .statement, type: .mysql)
        #expect(MCPFailure.databaseOperation(inner, phase: .execution, type: .mysql).details?.objectValue?["phase"] == "statement")
        #expect(MCPFailureCode.databaseNotFound.recovery.contains("list_databases without database"))
        #expect(MCPFailureCode.databaseAccessDenied.recovery.contains("separate from MCP"))
    }
}


struct MCPDatabaseFailureRuntimeTests {
    @Test(arguments: ["connect", "statement", "query_context", "execution", "transaction"])
    func runtimePreservesNativeDiagnosticsAndNeverRetries(_ phase: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DiagnosticFailureSession(failurePhase: phase)
        let runtime = MCPRuntime(directory: directory, registry: DatabaseDriverRegistry(drivers: [DiagnosticFailureDriver(session: session)]))
        let initial = MCPTests().profile()
        try await runtime.repository.insert(initial)
        let profile = try #require(try await runtime.repository.fetch(id: initial.id))
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.connections[profile.id.uuidString] = .init(mode: .fullAccess)
        try MCPPolicyStore(directory: directory).save(policy)
        let failure = await #expect(throws: MCPFailure.self) {
            if phase == "connect" {
                _ = try await runtime.call("querycraft_open_session", arguments: ["connection_id": .string(profile.id.uuidString), "database": "allowed"])
            } else if phase == "transaction" {
                try await runtime.transaction(.begin, entry: .init(id: "s", profile: profile, database: "allowed", connection: session, mode: .fullAccess))
            } else {
                _ = try await runtime.execute(phase == "execution" ? "list_databases" : "execute_query",
                    args: ["sql": "SELECT 1", "schema": "public"], profile: profile, database: "allowed", connection: session, policy: policy, inTransaction: false)
            }
        }
        #expect(failure?.code == .databaseNotFound)
        #expect(failure?.details?.objectValue?["phase"] == .string(phase))
        #expect(failure?.details?.objectValue?["native_code"] == 1049)
        #expect(await session.failureCount == 1)
        if phase == "connect" { #expect(await session.wasClosed) }
        await runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func batchKeepsDiagnosticsAndCountsWithoutRepeatingStatements(_ continueOnError: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DiagnosticFailureSession(failurePhase: "statement"), runtime = MCPRuntime(directory: directory)
        let initial = MCPTests().profile()
        try await runtime.repository.insert(initial)
        let profile = try #require(try await runtime.repository.fetch(id: initial.id))
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.connections[profile.id.uuidString] = .init(mode: .fullAccess)
        try MCPPolicyStore(directory: directory).save(policy)
        let args: [String: MCPJSONValue] = ["sql": "SELECT 1; SELECT 2", "continue_on_error": .bool(continueOnError), "result_mode": "detailed"]
        if continueOnError {
            let result = try await runtime.execute("execute_batch", args: args, profile: profile, database: "allowed", connection: session, policy: policy, inTransaction: false)
            #expect(result.objectValue?["failed"] == 2)
            let results = try #require(result.objectValue?["results"]?.arrayValue)
            #expect(results.count == 2)
            for item in results {
                let diagnostic = item.objectValue?["error"]?.objectValue
                #expect(diagnostic?["code"] == "DATABASE_NOT_FOUND")
                #expect(diagnostic?["details"]?.objectValue?["native_code"] == 1049)
                #expect(diagnostic?["details"]?.objectValue?["phase"] == "statement")
            }
        } else {
            let failure = await #expect(throws: MCPFailure.self) {
                _ = try await runtime.execute("execute_batch", args: args, profile: profile, database: "allowed", connection: session, policy: policy, inTransaction: false)
            }
            #expect(failure?.code == .databaseNotFound)
            #expect(failure?.details?.objectValue?["failed"] == 1)
            #expect(failure?.details?.objectValue?["native_code"] == 1049)
            #expect(failure?.details?.objectValue?["phase"] == "statement")
        }
        #expect(await session.failureCount == (continueOnError ? 2 : 1))
        await runtime.shutdown()
    }
}

private struct DiagnosticFailureDriver: DatabaseDriver {
    let databaseType = DatabaseType.mysql
    let session: DiagnosticFailureSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession { session }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}

private actor DiagnosticFailureSession: WorkspaceSession {
    let failurePhase: String
    var failureCount = 0
    var wasClosed = false
    init(failurePhase: String) { self.failurePhase = failurePhase }
    private func fail(_ phase: String) throws {
        if failurePhase == phase {
            failureCount += 1
            throw NSError(domain: "io.querycraft.driver.mariadb", code: 1049,
                userInfo: [NSLocalizedDescriptionKey: "fixture-secret", "sql_state": "42000"])
        }
    }
    func connect() async throws { try fail("connect") }
    func isConnected() async -> Bool { wasClosed == false }
    func fetchDatabases() async throws -> [String] { try fail("execution"); return [] }
    func applyQueryContext(_ context: WorkspaceQueryContext) async throws { try fail("query_context") }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { throw MCPFailure("unused") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw MCPFailure("unused") }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func executeReadOnlyQuery(_ sql: String, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        try fail("statement"); return .init(columns: [], rowCount: 0)
    }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        try fail(kind == .read ? "statement" : "transaction")
        return .init(columns: [], rowCount: 0)
    }
    func close() async { wasClosed = true }
}
