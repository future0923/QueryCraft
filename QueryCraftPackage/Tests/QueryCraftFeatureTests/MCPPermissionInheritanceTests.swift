import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPPermissionInheritanceTests {
    @Test(arguments: DatabaseType.allCases)
    func nearestExplicitRuleWinsAndRemovingItRestoresInheritance(_ type: DatabaseType) {
        let group = UUID(), profile = MCPTests().profile(type: type, group: nil)
        let grouped = ConnectionProfile(id: profile.id, name: profile.name, groupID: group,
            databaseType: type, host: profile.host, port: profile.port, username: profile.username,
            defaultDatabase: profile.defaultDatabase, tlsMode: .disabled, storesCredential: false, createdAt: Date())
        var policy = MCPPolicy()
        #expect(policy.effectiveMode(grouped, database: "allowed") == .readOnly)
        policy.groupModes[group.uuidString] = .dataWrite
        #expect(policy.effectiveMode(grouped, database: "allowed") == .dataWrite)
        policy.connections[profile.id.uuidString] = .init(mode: .fullAccess)
        #expect(policy.effectiveMode(grouped, database: "allowed") == .fullAccess)
        policy.connections[profile.id.uuidString]?.databaseModes["allowed"] = .readOnly
        #expect(policy.effectiveMode(grouped, database: "allowed") == .readOnly)
        #expect(policy.effectiveMode(grouped, database: "other") == .fullAccess)
        policy.connections[profile.id.uuidString]?.mode = .readOnly
        policy.connections[profile.id.uuidString]?.databaseModes["allowed"] = .fullAccess
        #expect(policy.effectiveMode(grouped, database: "allowed") == .fullAccess)
        #expect(policy.effectiveMode(grouped, database: "other") == .readOnly)
        policy.connections[profile.id.uuidString]?.databaseModes.removeValue(forKey: "allowed")
        #expect(policy.effectiveMode(grouped, database: "allowed") == .readOnly)
        policy.connections[profile.id.uuidString]?.mode = nil
        #expect(policy.effectiveMode(grouped, database: "allowed") == .dataWrite)
        policy.groupModes.removeValue(forKey: group.uuidString)
        #expect(policy.effectiveMode(grouped, database: "allowed") == .readOnly)
        #expect(policy.effectiveMode(grouped, database: nil) == .readOnly)
    }

    @Test(arguments: DatabaseType.allCases)
    func objectOverridesDoNotGrantConnectionsOrExpandAllowedNames(_ type: DatabaseType) throws {
        let profile = MCPTests().profile(type: type)
        var policy = MCPPolicy(); policy.enabled = true
        policy.connections[profile.id.uuidString] = .init(databases: ["allowed"], mode: .readOnly,
            databaseModes: ["allowed": .fullAccess, "private": .fullAccess], databaseAccess: .selected)
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "list_tables", profile: profile, database: "allowed") }
        policy.connectionIDs.insert(profile.id)
        try policy.authorize(tool: "list_tables", profile: profile, database: "allowed")
        #expect(MCPPermissionSummary.objectAccess("allowed", profile: profile, policy: policy) == MCPExecutionMode.fullAccess.title)
        #expect(MCPPermissionSummary.objectAccess("private", profile: profile, policy: policy) == MCPPermissionSelection.denied.title)
        if [.kafka, .elasticsearch].contains(type) {
            #expect(!policy.permitsObject("private", profile: profile))
        } else {
            #expect(throws: MCPFailure.self) { try policy.authorize(tool: "list_tables", profile: profile, database: "private") }
        }
        policy.connections[profile.id.uuidString]?.databaseAccess = MCPDatabaseAccess.none
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "list_tables", profile: profile, database: "allowed") }
    }

    @Test(arguments: MCPExecutionMode.allCases)
    func legacyGlobalModeIsIgnoredAndNoLongerSaved(_ legacyMode: MCPExecutionMode) throws {
        let profile = MCPTests().profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [profile.id]
        policy.connections[profile.id.uuidString] = .init(mode: .dataWrite, databaseModes: ["allowed": .fullAccess])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        #expect(json["mode"] == nil)
        json["mode"] = legacyMode.rawValue
        let restored = try JSONDecoder().decode(MCPPolicy.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored == policy)
        #expect(restored.effectiveMode(profile, database: "allowed") == .fullAccess)
        #expect(restored.effectiveMode(profile, database: "other") == .dataWrite)
        var noRules = restored; noRules.connections = [:]
        #expect(noRules.effectiveMode(profile, database: "allowed") == .readOnly)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(saved["mode"] == nil)
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris])
    func sqlExecutionUsesExplicitDatabaseAccessOverReadOnlyConnection(_ type: DatabaseType) async throws {
        let profile = MCPTests().profile(type: type)
        var policy = MCPPolicy()
        policy.connections[profile.id.uuidString] = .init(mode: .readOnly, databaseModes: ["allowed": .dataWrite, "admin": .fullAccess])
        let insert = try await MCPSQLAuthorization.statements("INSERT INTO users (id) VALUES (1)", profile: profile, database: "allowed", policy: policy)
        #expect(insert.count == 1)
        let ddl = try await MCPSQLAuthorization.statements("CREATE TABLE users (id INT)", profile: profile, database: "admin", policy: policy)
        #expect(ddl.count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await MCPSQLAuthorization.statements("INSERT INTO users (id) VALUES (1)", profile: profile, database: "other", policy: policy)
        }
        policy.connections[profile.id.uuidString]?.mode = .fullAccess
        policy.connections[profile.id.uuidString]?.databaseModes["allowed"] = .readOnly
        await #expect(throws: (any Error).self) {
            _ = try await MCPSQLAuthorization.statements("INSERT INTO users (id) VALUES (1)", profile: profile, database: "allowed", policy: policy)
        }
    }

    @MainActor @Test func summaryIncludesObjectOverridesThatRaiseAccess() {
        let profile = MCPTests().profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [profile.id]
        policy.connections[profile.id.uuidString] = .init(mode: .readOnly, databaseModes: ["allowed": .fullAccess])
        #expect(MCPPermissionSummary.access(profile, policy: policy).contains(AppCopy.current.text("部分对象单独设置", "object overrides")))
        #expect(MCPPermissionSummary.objectAccess("allowed", profile: profile, policy: policy) == MCPExecutionMode.fullAccess.title)
        #expect(MCPPermissionSummary.objectAccess("other", profile: profile, policy: policy) == MCPExecutionMode.readOnly.title)
    }
}

extension MCPPermissionInheritanceTests {
    @Test(arguments: [DatabaseType.redis, .elasticsearch, .kafka])
    func driverCallsAndDelegatedCallsUseObjectOverrides(_ type: DatabaseType) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ConnectionProfile(id: UUID(), name: "permission fixture", groupID: nil, databaseType: type,
            host: "localhost", port: 1234, username: "fixture", defaultDatabase: type == .redis ? "0" : "allowed",
            tlsMode: .disabled, storesCredential: false, createdAt: Date())
        let session = PermissionDriverSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: type, session: session)]))
        try await runtime.repository.insert(profile)
        let target = type == .redis ? "0" : "allowed"
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [profile.id]
        policy.connections[profile.id.uuidString] = .init(databases: [target], mode: .readOnly,
            databaseModes: [target: .dataWrite], databaseAccess: .selected)
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let tool: String
        var args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString)]
        switch type {
        case .redis:
            tool = "execute_redis_command"; args["database"] = "0"
            args["arguments"] = .array(["SET", "fixture", "value"])
        case .elasticsearch:
            tool = "execute_request"; args["method"] = "PUT"
            args["path"] = "/allowed/_doc/1"; args["body"] = "{\"v\":\"fixture\"}"
        default:
            tool = "send_message"; args["topic"] = "allowed"; args["value"] = "fixture"
        }
        _ = try await runtime.call("querycraft_" + tool, arguments: args)
        let delegated: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "tool": .string(tool), "arguments": .object(args)]
        _ = try await runtime.call("querycraft_plugin_call", arguments: delegated)
        #expect(await session.writes == 2)
        policy.connections[profile.id.uuidString]?.mode = .fullAccess
        policy.connections[profile.id.uuidString]?.databaseModes[target] = .readOnly
        try store.save(policy)
        await #expect(throws: (any Error).self) { _ = try await runtime.call("querycraft_" + tool, arguments: args) }
        await #expect(throws: (any Error).self) { _ = try await runtime.call("querycraft_plugin_call", arguments: delegated) }
        #expect(await session.writes == 2)
        policy.connections[profile.id.uuidString]?.mode = .readOnly
        policy.connections[profile.id.uuidString]?.databaseModes.removeValue(forKey: target)
        try store.save(policy)
        await #expect(throws: (any Error).self) { _ = try await runtime.call("querycraft_" + tool, arguments: args) }
        #expect(await session.writes == 2)
        await runtime.shutdown()
    }
}

private struct PermissionDriver: DatabaseDriver {
    let databaseType: DatabaseType
    let session: PermissionDriverSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession { session }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}

private actor PermissionDriverSession: RedisWorkspaceSession, WorkspaceRequestExecutingSession, WorkspaceKafkaProducing {
    var writes = 0
    func connect() async throws {}
    func fetchDatabases() async throws -> [String] { [] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { throw MCPFailure("unused") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { throw MCPFailure("unused") }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func close() async {}
    func fetchRedisLogicalDatabases() async throws -> [RedisLogicalDatabase] { [] }
    func scanRedisKeys(databaseIndex: Int, cursor: UInt64, pattern: String?, count: Int) async throws -> RedisKeyScanPage { throw MCPFailure("unused") }
    func fetchRedisKey(_ reference: RedisKeyReference, maximumElements: Int) async throws -> RedisKeyDetails { throw MCPFailure("unused") }
    func executeRedisCommand(_ invocation: RedisCommandInvocation, databaseIndex: Int) async throws -> RedisCommandResult {
        writes += 1; return .init(invocation: invocation, reply: .simpleString("OK"), elapsedSeconds: 0)
    }
    func executeRequest(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult { throw MCPFailure("unused") }
    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        if policy == .readOnly { try WorkspaceReadOnlyRequestValidator.validate(request) }
        writes += 1; return .init(statusCode: 200, contentType: "application/json", body: Data("{}".utf8))
    }
    func produce(_ request: WorkspaceKafkaProduceRequest) async throws -> WorkspaceKafkaProduceReceipt {
        writes += 1; return .init(partition: 0, offset: 1)
    }
}
