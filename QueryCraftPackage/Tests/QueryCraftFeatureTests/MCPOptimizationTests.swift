import Foundation
import MCP
import Testing
@testable import QueryCraftFeature

struct MCPOptimizationTests {
    @Test func kafkaWithoutSavedDatabaseUsesDriverNamespace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: root).save(policy)
        let driver = MCPProbeDriver(databaseType: .kafka)
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        let profile = ConnectionProfile(id: UUID(), name: "Kafka", groupID: nil, databaseType: .kafka,
            host: "localhost", port: 9092, username: "", authenticationMethod: .none,
            defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: Date())
        try await runtime.repository.insert(profile)
        _ = try await runtime.call("querycraft_list_tables", arguments: ["connection_id": .string(profile.id.uuidString)])
        let session = try #require(await driver.created.first)
        #expect(await session.metadataDatabases == ["Kafka"])
        await runtime.shutdown()
    }
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func metadataCacheRefreshAndRevocationFollowDriverScope(_ type: DatabaseType) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let driver = MCPProbeDriver(databaseType: type)
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        let p = MCPTests().profile(type: type); try await runtime.repository.insert(p)
        var args: [String: Value] = ["connection_id": .string(p.id.uuidString)]
        _ = try await runtime.call("querycraft_list_tables", arguments: args)
        _ = try await runtime.call("querycraft_list_tables", arguments: args)
        #expect(await driver.createdCount == 1)
        let session = try #require(await driver.created.first)
        #expect(await session.metadataReads == (type == .redis ? 2 : 1))
        args["refresh"] = true
        _ = try await runtime.call("querycraft_list_tables", arguments: args)
        #expect(await session.metadataReads == (type == .redis ? 3 : 2))
        policy.connections[p.id.uuidString] = .init(databaseAccess: MCPDatabaseAccess.none); try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_list_tables", arguments: args) }
        await runtime.retireIdleConnections(policy: policy, now: Date().addingTimeInterval(61))
        #expect(await session.closed)
        await runtime.shutdown()
    }
    @Test func ddlInvalidatesMetadataAndSQLNeverBorrowsMetadataConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true; policy.mode = .fullAccess
        try MCPPolicyStore(directory: root).save(policy)
        let driver = MCPProbeDriver(databaseType: .mysql)
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        let p = MCPTests().profile(); try await runtime.repository.insert(p)
        let args: [String: Value] = ["connection_id": .string(p.id.uuidString)]
        _ = try await runtime.call("querycraft_list_tables", arguments: args)
        let metadata = try #require(await driver.created.first)
        _ = try await runtime.call("querycraft_execute_query", arguments: args.merging(["sql": "CREATE TABLE audit_log (id INT)", "confirm_high_risk": true]) { _, b in b })
        #expect(await driver.createdCount == 2)
        #expect(await metadata.statements.isEmpty)
        _ = try await runtime.call("querycraft_list_tables", arguments: args)
        #expect(await metadata.metadataReads == 2)
        let created = await driver.created
        #expect(await created[1].closed)
        let session = try await runtime.call("querycraft_open_session", arguments: args)
        #expect(await driver.createdCount == 3)
        _ = try await runtime.call("querycraft_close_session", arguments: ["session_id": try #require(session.objectValue?["session_id"])])
        await runtime.shutdown()
        #expect(await metadata.closed)
    }
    @Test func cachedMetadataExpiresAndConnectionChangesCannotHitIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root)
        let p = MCPTests().profile()
        try await runtime.cacheMetadata("old", key: "test", profile: p, policy: policy, generation: 0)
        #expect(await runtime.cachedMetadata(key: "test", profile: p, policy: policy, refresh: false) == "old")
        #expect(await runtime.cachedMetadata(key: "test", profile: p, policy: policy, refresh: false, now: Date().addingTimeInterval(31)) == nil)
        try await runtime.cacheMetadata("old", key: "test", profile: p, policy: policy, generation: 0)
        let changed = ConnectionProfile(id: p.id, name: p.name, groupID: nil, host: "different-host", port: p.port, username: p.username, defaultDatabase: p.defaultDatabase, tlsMode: p.tlsMode, storesCredential: false, createdAt: p.createdAt)
        #expect(await runtime.cachedMetadata(key: "test", profile: changed, policy: policy, refresh: false) == nil)
        await runtime.invalidateMetadata(for: p.id)
        try await runtime.cacheMetadata("late", key: "test", profile: p, policy: policy, generation: 0)
        #expect(await runtime.cachedMetadata(key: "test", profile: p, policy: policy, refresh: false) == nil)
        await runtime.shutdown()
    }
    @Test func lazyDiscoveryCallsTheSameAuthorizedDriverRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.optimizations = .init(discovery: .lazy)
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let driver = MCPProbeDriver(databaseType: .mysql), p = MCPTests().profile()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        try await runtime.repository.insert(p)
        let names = try await runtime.tools().map(\.name)
        #expect(names.contains("querycraft_plugin_tools"))
        #expect(!names.contains("querycraft_execute_query"))
        #expect(names.contains("querycraft_rollback_transaction"))
        let args: [String: Value] = ["connection_id": .string(p.id.uuidString)]
        let schemas = try await runtime.call("querycraft_plugin_tools", arguments: args)
        #expect(schemas.arrayValue?.contains { $0.objectValue?["name"] == "execute_query" } == true)
        let callArgs = args.merging(["tool": "list_tables", "arguments": .object([:])]) { _, b in b }
        _ = try await runtime.call("querycraft_plugin_call", arguments: callArgs)
        policy.disabledTools.insert("list_tables"); try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_plugin_call", arguments: callArgs) }
        let records = try await runtime.history.recent()
        #expect(records.count == 3) // Discovery, delegated call, rejected delegated call; no duplicate internal records.
        #expect(records.first?.errorCode == MCPFailureCode.accessDenied.rawValue)
        await runtime.shutdown()
    }
    @Test func compactSchemaAndCellWindowsHaveExplicitBounds() async throws {
        let column = WorkspaceDatabaseColumn(name: "id", type: "bigint", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: String(repeating: "注释", count: 200))
        let detail = WorkspaceDatabaseObjectDetails(columns: Array(repeating: column, count: 100), ddl: "SECRET DDL SHOULD NOT BE DUPLICATED")
        let value = MCPSchemaContext.compact(profile: MCPTests().profile(), database: "allowed", tables: [(.init(name: "users", kind: .table), detail)], omittedTables: 3, budget: 1200)
        let context = try #require(value.objectValue?["context"]?.stringValue)
        #expect(context.count <= 1200); #expect(context.contains("id bigint NOT NULL PRI"))
        #expect(!context.contains("SECRET DDL")); #expect(value.objectValue?["truncated"] == true)
        let buffer = MCPResultBuffer(limit: 10, byteLimit: 4096, cellLimit: 2)
        try await buffer.append(.init(columns: [.init(id: 0, name: "value", type: "text")], rows: [.init(id: 1, values: [.text("你🙂好abc")])]))
        let result = await buffer.value()
        let cell = try #require(result.objectValue?["rows"]?.arrayValue?.first?.arrayValue?.first?.objectValue)
        #expect(cell["text"] == "你🙂"); #expect(cell["next_offset"] == .int(2))
        let tail = MCPResultBuffer(limit: 1, byteLimit: 4096, cellOffset: 2, cellLimit: 20)
        try await tail.append(.init(columns: [], rows: [.init(id: 1, values: [.text("你🙂好abc")])]))
        let next = await tail.value()
        #expect(next.objectValue?["rows"]?.arrayValue?.first?.arrayValue?.first?.objectValue?["next_offset"] == .null)
    }
    @Test func historyIsBoundedAndDoesNotContainQueryValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: root).save(policy)
        let driver = MCPProbeDriver(databaseType: .mysql), p = MCPTests().profile()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        try await runtime.repository.insert(p)
        _ = try await runtime.call("querycraft_execute_query", arguments: ["connection_id": .string(p.id.uuidString), "sql": "SELECT 'private-test-value-123'", "max_rows": .int(5)])
        let history = await runtime.history
        let initial = try await history.recent()
        #expect(initial.count == 1); #expect(initial[0].succeeded)
        for index in 0..<502 {
            try await history.append(.init(id: UUID().uuidString, startedAt: Date().addingTimeInterval(Double(index)), tool: "querycraft_list_tables", connectionID: p.id.uuidString, durationMilliseconds: 1, succeeded: true, errorCode: nil, resultBytes: 2))
        }
        #expect(try await history.recent(limit: 1000).count == 500)
        let data = try Data(contentsOf: root.appending(path: "MCP/History/calls.sqlite"))
        #expect(data.range(of: Data("private-test-value-123".utf8)) == nil)
        try await history.clear(); #expect(try await history.recent().isEmpty)
        await runtime.shutdown()
    }
    @Test func concurrentMetadataCallsNeverShareAnActiveConnection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true; policy.maximumSessions = 1
        policy.optimizations = .init(metadataCacheSeconds: 0)
        try MCPPolicyStore(directory: root).save(policy)
        let started = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let driver = MCPProbeDriver(databaseType: .mysql, started: started.continuation, release: release.stream)
        let p = MCPTests().profile(), runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [driver]))
        try await runtime.repository.insert(p)
        let args: [String: Value] = ["connection_id": .string(p.id.uuidString)]
        let first = Task {
            do { return try await runtime.call("querycraft_list_tables", arguments: args) }
            catch { started.continuation.finish(); throw error }
        }
        for await _ in started.stream { break }
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_list_tables", arguments: args) }
        #expect(await driver.createdCount == 1)
        release.continuation.finish(); _ = try await first.value
        _ = try await runtime.call("querycraft_list_tables", arguments: args)
        #expect(await driver.createdCount == 1)
        await runtime.shutdown()
    }
    @Test func installedSkillRefusesSymlinkAndUnmanagedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source"), target = root.appending(path: "target"), external = root.appending(path: "external")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("bundled".utf8).write(to: source.appending(path: "SKILL.md"))
        let installer = MCPSkillInstallation(source: source)
        try await installer.install(at: target)
        try Data("user data".utf8).write(to: target.appending(path: "extra.txt"))
        #expect(try await installer.status(at: target) == .modified)
        await #expect(throws: MCPFailure.self) { try await installer.uninstall(at: target) }
        try FileManager.default.removeItem(at: target.appending(path: "extra.txt"))
        try await installer.uninstall(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        await #expect(throws: MCPFailure.self) { try await installer.install(at: target) }
        #expect(FileManager.default.fileExists(atPath: external.path))
    }
    @Test func optionalSkillLifecyclePreservesLocalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source"), target = root.appending(path: "skills/querycraft")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("version one".utf8).write(to: source.appending(path: "SKILL.md"))
        let installer = MCPSkillInstallation(source: source)
        #expect(try await installer.status(at: target) == .notInstalled)
        try await installer.install(at: target); #expect(try await installer.status(at: target) == .current)
        try Data("version two".utf8).write(to: source.appending(path: "SKILL.md"))
        #expect(try await installer.status(at: target) == .updateAvailable)
        try await installer.install(at: target)
        #expect(try String(contentsOf: target.appending(path: "SKILL.md"), encoding: .utf8) == "version two")
        try Data("my custom workflow".utf8).write(to: target.appending(path: "SKILL.md"))
        #expect(try await installer.status(at: target) == .modified)
        await #expect(throws: MCPFailure.self) { try await installer.install(at: target) }
        await #expect(throws: MCPFailure.self) { try await installer.uninstall(at: target) }
        #expect(try String(contentsOf: target.appending(path: "SKILL.md"), encoding: .utf8) == "my custom workflow")
        try Data("version two".utf8).write(to: target.appending(path: "SKILL.md"))
        try await installer.uninstall(at: target); #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

private actor MCPProbeDriver: DatabaseDriver {
    nonisolated let databaseType: DatabaseType
    var created: [MCPProbeSession] = []
    let started: AsyncStream<Void>.Continuation?
    let release: AsyncStream<Void>?
    var createdCount: Int { created.count }
    init(databaseType: DatabaseType, started: AsyncStream<Void>.Continuation? = nil, release: AsyncStream<Void>? = nil) {
        self.databaseType = databaseType; self.started = started; self.release = release
    }
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession {
        let session = MCPProbeSession(started: started, release: release); created.append(session); return session
    }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}
private actor MCPProbeSession: WorkspaceSession {
    let started: AsyncStream<Void>.Continuation?
    let release: AsyncStream<Void>?
    init(started: AsyncStream<Void>.Continuation? = nil, release: AsyncStream<Void>? = nil) { self.started = started; self.release = release }
    var closed = false
    var metadataReads = 0
    var metadataDatabases: [String] = []
    var statements: [String] = []
    var state = WorkspaceQueryTransactionState.autoCommit
    func connect() async throws {}
    func isConnected() async -> Bool { !closed }
    func close() async { closed = true }
    func fetchDatabases() async throws -> [String] { ["allowed"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] {
        metadataReads += 1
        metadataDatabases.append(database)
        started?.yield(())
        if let release { for await _ in release { break } }
        return [.init(name: "users", kind: .table)]
    }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { .init(columns: [], ddl: "CREATE TABLE users (id INT)") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw MCPFailure("unused") }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func executeReadOnlyQuery(_ sql: String, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult { .init(columns: [], rowCount: 0) }
    func executeStatement(_ sql: String, kind: SQLStatementKind, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult {
        statements.append(sql); state = try state.afterSuccessfulStatement(kind); return .init(columns: [], rowCount: 0)
    }
}
