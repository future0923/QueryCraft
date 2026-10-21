import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPSessionTests {
    @Test func concurrentCallsReserveSessionAndCorruptPolicyStillAllowsCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: directory).save(policy)
        let initialProfile = MCPTests().profile()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let session = MCPBlockingSession(started: started.continuation, release: release.stream)
        let runtime = MCPRuntime(directory: directory)
        try await runtime.repository.insert(initialProfile)
        let profile = try #require(try await runtime.repository.fetch(id: initialProfile.id))
        await runtime.seedMCPTestSession(.init(id: "session", profile: profile, database: "allowed", connection: session, mode: .readOnly))
        let args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "session_id": "session", "sql": "SELECT 1"]
        let first = Task {
            do { return try await runtime.call("querycraft_execute_query", arguments: args) }
            catch { started.continuation.finish(); throw error }
        }
        for await _ in started.stream { break }
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_execute_query", arguments: args) }
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_close_session", arguments: ["session_id": "session"]) }
        release.continuation.yield(()); release.continuation.finish()
        _ = try await first.value
        try Data("broken".utf8).write(to: MCPPolicyStore(directory: directory).url)
        let closed = try await runtime.call("querycraft_close_session", arguments: ["session_id": "session"])
        #expect(closed.objectValue?["status"] == "closed")
        #expect(await session.wasClosed)
        #expect(await session.executions == 1)
        await runtime.shutdown()
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql])
    func readonlyConnectionAndQueriesUseTrackedTransactions(_ type: DatabaseType) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: directory).save(policy)
        let session = MCPBlockingSession()
        let runtime = MCPRuntime(directory: directory, registry: DatabaseDriverRegistry(drivers: [MCPRecordingDriver(databaseType: type, session: session)]))
        let profile = MCPTests().profile(type: type)
        _ = try await runtime.connect(profile, database: "allowed", mode: .readOnly)
        #expect(await session.statements.isEmpty)
        _ = try await runtime.execute("execute_query", args: ["sql": "SELECT 1"], profile: profile, database: "allowed", connection: session, policy: policy, inTransaction: false)
        #expect(await session.statements == ["START TRANSACTION READ ONLY", "SELECT 1", "ROLLBACK"])
        #expect(await session.state == .autoCommit)
        try await runtime.transaction(.begin, entry: .init(id: "s", profile: profile, database: "allowed", connection: session, mode: .readOnly))
        _ = try await runtime.execute("execute_query", args: ["sql": "SELECT 2"], profile: profile, database: "allowed", connection: session, policy: policy, inTransaction: true)
        #expect(await session.state == .inTransaction)
        #expect(await session.statements.suffix(2) == ["START TRANSACTION READ ONLY", "SELECT 2"])
        await runtime.shutdown()
    }
    @Test func queryFailureRollsBackAndAtomicDDLNeverReachesDriver() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: directory).save(policy)
        let session = MCPBlockingSession(failQuery: true), runtime = MCPRuntime(directory: directory)
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.execute("execute_query", args: ["sql": "SELECT 1"], profile: MCPTests().profile(), database: "allowed", connection: session, policy: policy, inTransaction: false)
        }
        #expect(await session.statements == ["START TRANSACTION READ ONLY", "SELECT 1", "ROLLBACK"])
        #expect(await session.state == .autoCommit)
        policy.mode = .fullAccess; try MCPPolicyStore(directory: directory).save(policy)
        let clean = MCPBlockingSession()
        for type in [DatabaseType.mysql, .postgresql] {
            await #expect(throws: MCPFailure.self) {
                _ = try await runtime.execute("execute_batch", args: ["sql": "DROP TABLE users", "use_transaction": true, "confirm_high_risk": true], profile: MCPTests().profile(type: type), database: "allowed", connection: clean, policy: policy, inTransaction: false)
            }
        }
        #expect(await clean.statements.isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await MCPSQLAuthorization.statements("SET autocommit=1", profile: MCPTests().profile(), database: "allowed", policy: policy)
        }
        await runtime.shutdown()
    }

    @Test @MainActor func nativeResultKeepsNullAndIntegerPrecision() async throws {
        let value: MCPJSONValue = .object(["results": .array([.object([
            "sql": "SELECT value", "affected_or_returned_rows": .int(1),
            "result": .object(["columns": .array([.object(["name": "a", "type": "bigint"]), .object(["name": "b", "type": "text"])]),
                               "rows": .array([.array(["9007199254740993", .null])])])
        ])])])
        let results = try await MCPResultWindowController.decodeResults(value)
        #expect(results[0].state.page?.row(at: 0)?.values == [.text("9007199254740993"), .null])
    }
}

private extension MCPRuntime {
    func seedMCPTestSession(_ entry: Session) { sessions[entry.id] = entry }
}

private actor MCPBlockingSession: WorkspaceSession {
    let started: AsyncStream<Void>.Continuation?
    let release: AsyncStream<Void>?
    let failQuery: Bool
    var state = WorkspaceQueryTransactionState.autoCommit
    var statements: [String] = []
    var wasClosed = false
    var executions = 0
    init(started: AsyncStream<Void>.Continuation? = nil, release: AsyncStream<Void>? = nil, failQuery: Bool = false) { self.started = started; self.release = release; self.failQuery = failQuery }
    func connect() async throws {}
    func isConnected() async -> Bool { !wasClosed }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { throw MCPFailure("unused") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
                       onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw MCPFailure("unused") }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func executeReadOnlyQuery(_ sql: String, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        executions += 1; started?.yield(()); started?.finish()
        if let release { for await _ in release { break } }
        if failQuery { throw MCPFailure("query failed") }
        return .init(columns: [], rowCount: 0)
    }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        statements.append(sql)
        // Same post-execution state contract as the real SQL drivers.
        let next = try state.afterSuccessfulStatement(kind)
        if kind == .read { _ = try await executeReadOnlyQuery(sql, database: database, onBatch: onBatch) }
        state = next
        return .init(columns: [], rowCount: 0)
    }
    func close() async { wasClosed = true }

}

private struct MCPRecordingDriver: DatabaseDriver {
    let databaseType: DatabaseType
    let session: MCPBlockingSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession { session }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}
