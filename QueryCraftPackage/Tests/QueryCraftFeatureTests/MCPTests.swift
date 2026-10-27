import Foundation
import Testing
import Security
@testable import QueryCraftFeature

struct MCPTests {
    @Test func permissionGroupsCoverEveryToolOnceIncludingAllDrivers() {
        let names = MCPPermissionToolGroup.allCases.flatMap { $0.tools.map(\.name) }
        #expect(Set(names) == Set(MCPToolCatalog.definitions.map(\.name)))
        #expect(names.count == Set(names).count)
        for driver in DatabaseType.allCases {
            #expect(MCPToolCatalog.driverTools(driver).isSubset(of: Set(names)))
        }
    }
    @Test func credentialErrorsProvideRecoveryWithoutLeakingDetails() {
        let cases: [(OSStatus, MCPFailureCode)] = [
            (errSecUserCanceled, .credentialCancelled),
            (errSecAuthFailed, .credentialDenied),
            (errSecInteractionNotAllowed, .credentialDenied),
            (errSecItemNotFound, .credentialUnavailable)
        ]
        for (status, code) in cases {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                                userInfo: [NSLocalizedDescriptionKey: "fixture-secret"])
            let failure = MCPFailure.normalized(error)
            #expect(failure.code == code)
            #expect(!failure.message.contains("fixture-secret"))
            #expect(failure.code.recovery.contains("Authorize saved credentials"))
            #expect(MCPFailure.normalized(KeychainError(status: status)).code == code)
        }
        #expect(MCPFailure.normalized(CancellationError()).code == .cancelled)
    }
    @Test func connectionCreationPreservesTransportAndAuthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root)
        let args: [String: MCPJSONValue] = ["name": "Kafka", "type": "kafka", "host": "localhost", "port": 9092, "tls_mode": "disabled"]
        let result = try await runtime.call("querycraft_add_connection", arguments: args)
        let id = try #require(result.objectValue?["connection_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let saved = try #require(try await runtime.repository.fetch(id: id))
        #expect(saved.authenticationMethod == .none)
        #expect(saved.tlsMode == .disabled)
        #expect(!saved.storesCredential)
        #expect(result.objectValue?["authorized"] == false)
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_add_connection", arguments: args.merging(["authentication": "apiKey"]) { _, b in b })
        }
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_add_connection", arguments: args.merging(["kafka_sasl_mechanism": "SCRAM-SHA-256"]) { _, b in b })
        }
        await runtime.shutdown()
    }
    func profile(type: DatabaseType = .mysql, group: UUID? = nil) -> ConnectionProfile {
        .init(id: UUID(), name: "test", groupID: group, databaseType: type, host: "localhost", port: 3306,
              username: "test", defaultDatabase: "allowed", tlsMode: .disabled, storesCredential: false, createdAt: Date())
    }
    @Test func missingPolicyDeniesAccess() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let policy = try MCPPolicyStore(directory: root).load()
        #expect(!policy.enabled)
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "list_connections") }
    }
    @Test func connectionAndDatabasePermissionsAreIndependent() throws {
        let p = profile(); var policy = MCPPolicy(); policy.enabled = true
        #expect(!policy.permits(p))
        policy.connectionIDs.insert(p.id)
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"])
        try policy.authorize(tool: "execute_query", profile: p, database: "allowed")
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "execute_query", profile: p, database: "other") }
        policy.disabledTools.insert("execute_query")
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "execute_query", profile: p, database: "allowed") }
    }
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func databaseScopeRetainsSelectionsAndDeniesEveryDriver(_ type: DatabaseType) throws {
        let p = profile(type: type); var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        var rule = MCPConnectionPolicy(databases: ["allowed"])
        #expect(rule.scope == .selected)
        rule.databaseAccess = .all; #expect(rule.allowedDatabases == nil)
        rule.databaseAccess = MCPDatabaseAccess.none; policy.connections[p.id.uuidString] = rule
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "list_databases", profile: p, database: "allowed") }
        rule.databaseAccess = .selected
        #expect(rule.allowedDatabases == ["allowed"])
        let restored = try JSONDecoder().decode(MCPConnectionPolicy.self, from: JSONEncoder().encode(rule))
        #expect(restored.allowedDatabases == ["allowed"])
        policy.connections[p.id.uuidString] = restored
        try policy.authorize(tool: "list_databases", profile: p, database: "allowed")
    }
    @Test func timeoutSupportsInheritanceAndUnlimited() throws {
        var policy = MCPPolicy()
        #expect(policy.effectiveQueryTimeoutSeconds == 60)
        policy.inheritedQueryTimeoutSeconds = 120; #expect(policy.effectiveQueryTimeoutSeconds == 120)
        policy.queryTimeoutSeconds = 0; try policy.validate(); #expect(policy.effectiveQueryTimeoutSeconds == 0)
        policy.queryTimeoutSeconds = -1; #expect(throws: MCPFailure.self) { try policy.validate() }
    }
    @Test func allClientTemplatesUseTheirNativeFormats() throws {
        #expect(MCPClientConfiguration.clients.count == 12)
        for client in MCPClientConfiguration.clients {
            let config = MCPClientConfiguration.make(client: client, executable: "/Applications/Test App/mcp", dataDirectory: "/tmp/data", http: nil)
            if client == "Codex" { #expect(config.hasPrefix("[mcp_servers.querycraft]")); continue }
            if client == "DeepSeek Harness" { #expect(config.contains("@deepseek-ai/dsh-mcp-client")); #expect(config.contains("transport: stdio")); continue }
            let root = try #require(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: [String: [String: Any]]])
            let key = client == "VS Code" ? "servers" : client == "OpenCode" ? "mcp" : "mcpServers"
            let server = try #require(root[key]?["querycraft"])
            if client == "OpenCode" { #expect((server["command"] as? [String])?.first == "/Applications/Test App/mcp") }
            else { #expect(server["command"] as? String == "/Applications/Test App/mcp") }
            if client == "Cherry Studio" { #expect(server["isActive"] as? Bool == true); #expect(server["type"] as? String == "stdio") }
        }
    }
    @Test func developmentClientTemplatesUseSeparateNames() throws {
        for client in MCPClientConfiguration.clients {
            for http in [false, true] where !http || MCPClientConfiguration.supportsHTTP(client) {
                let config = MCPClientConfiguration.make(client: client, executable: "/tmp/QueryCraftDev/MCP/bin/querycraft-mcp",
                    dataDirectory: "/tmp/QueryCraftDev/", http: http ? MCPHTTPSettings() : nil)
                if client == "Codex" { #expect(config.hasPrefix("[mcp_servers.querycraft-dev]")); continue }
                if client == "DeepSeek Harness" { #expect(config.contains("serverName: querycraft-dev")); continue }
                let root = try #require(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: [String: [String: Any]]])
                let key = client == "VS Code" ? "servers" : client == "OpenCode" ? "mcp" : "mcpServers"
                let server = try #require(root[key]?["querycraft-dev"])
                #expect(root[key]?["querycraft"] == nil)
                if client == "Cherry Studio" { #expect(server["name"] as? String == "QueryCraft Dev") }
            }
        }
    }
    @Test func revocationIsReadFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPPolicyStore(directory: root); var policy = MCPPolicy(); policy.enabled = true
        try store.save(policy); #expect(try store.load().enabled)
        policy.enabled = false; try store.save(policy); #expect(try !store.load().enabled)
        try Data("{}".utf8).write(to: store.url)
        #expect(throws: (any Error).self) { _ = try store.load() }
    }
    @Test func remoteHTTPRequiresExplicitAllowLists() throws {
        var http = MCPHTTPSettings(); try http.validate()
        http.host = "0.0.0.0"
        #expect(throws: MCPFailure.self) { try http.validate() }
        http.allowsRemote = true; http.allowedHosts = ["db.example.test"]; http.allowedOrigins = ["https://client.example.test"]
        try http.validate()
        http.allowedOrigins = ["*"]
        #expect(throws: MCPFailure.self) { try http.validate() }
    }
    @Test func configEscapesPathsAndUsesCorrectClientShape() throws {
        let path = "/Users/Test Person/a\"b/querycraft-mcp"
        let config = MCPClientConfiguration.make(client: "VS Code", executable: path, dataDirectory: "/tmp/data", http: nil)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let servers = try #require(json["servers"] as? [String: [String: Any]])
        #expect(servers["querycraft"]?["command"] as? String == path)
        #expect(servers["querycraft"]?["type"] as? String == "stdio")
    }
    @Test func resultPreservesNullPrecisionAndTruncation() async throws {
        let buffer = MCPResultBuffer(limit: 1, byteLimit: 1024, cellLimit: 4)
        try await buffer.append(.init(columns: [.init(id: 0, name: "value", type: "text")], rows: [
            .init(id: 1, values: [.null, .text("9007199254740993")]), .init(id: 2, values: [.text("second")])]))
        let value = await buffer.value()
        #expect(value.objectValue?["truncated"]?.boolValue == true)
        let row = try #require(value.objectValue?["rows"]?.arrayValue?.first?.arrayValue)
        #expect(row[0] == .null)
        #expect(row[1].objectValue?["text"]?.stringValue == "9007")
    }
    @Test func sqlRejectsWriteTailAndCrossDatabaseRead() async throws {
        let p = profile(); var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        await #expect(throws: MCPFailure.self) {
            _ = try await MCPSQLAuthorization.statements("SELECT 1; DELETE FROM users", profile: p, database: "allowed", policy: policy)
        }
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"])
        await #expect(throws: MCPFailure.self) {
            _ = try await MCPSQLAuthorization.statements("SELECT * FROM other.users", profile: p, database: "allowed", policy: policy)
        }
    }
    @Test func sqlDataWriteRejectsUnboundedDeletionAndRawTransactions() async throws {
        let p = profile(); var policy = MCPPolicy(); policy.connections[p.id.uuidString] = .init(mode: .dataWrite)
        await #expect(throws: MCPFailure.self) { _ = try await MCPSQLAuthorization.statements("DELETE FROM users", profile: p, database: "allowed", policy: policy) }
        await #expect(throws: MCPFailure.self) { _ = try await MCPSQLAuthorization.statements("BEGIN", profile: p, database: "allowed", policy: policy) }
    }
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], MCPExecutionMode.allCases)
    func contextFunctionsWorkWithoutUnrestrictedFullAccess(_ driver: DatabaseType, _ mode: MCPExecutionMode) async throws {
        let p = profile(type: driver)
        let context = driver == .postgresql ? "CURRENT_DATABASE(), CURRENT_SCHEMA()" : "DATABASE(), SCHEMA()"
        let sql = "SELECT 1 AS connection_ok, \(context), VERSION() AS server_version"
        let scopes: [Set<String>?] = [nil, ["allowed"]]
        for databases in scopes {
            var policy = MCPPolicy()
            policy.connections[p.id.uuidString] = .init(databases: databases, mode: mode)
            let statements = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
            #expect(statements.map(\.kind) == [.read])
            #expect(statements.first?.sql == sql)
            let nested = try await MCPSQLAuthorization.statements("SELECT COALESCE(version( /* context */ ), 'unknown')", profile: p, database: "allowed", policy: policy)
            #expect(nested.map(\.kind) == [.read])
        }
    }
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], [MCPExecutionMode.readOnly, .dataWrite])
    func contextFunctionPermissionDoesNotAuthorizeRoutinesOrArguments(_ driver: DatabaseType, _ mode: MCPExecutionMode) async throws {
        let p = profile(type: driver)
        var policy = MCPPolicy()
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: mode)
        for sql in ["SELECT allowed.version()", "SELECT version(1)", "SELECT version(evil_function())", "SELECT VERSION(), evil_function()"] {
            do {
                _ = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
                Issue.record("Unverified SQL function was authorized: \(sql)")
            } catch let failure as MCPFailure {
                #expect(failure.code == .accessDenied)
            }
        }
    }
    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris])
    func contextFunctionsPreserveDatabaseScopeAndMetadataDiscovery(_ driver: DatabaseType) async throws {
        let p = profile(type: driver)
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .fullAccess)
        try policy.authorize(tool: "list_databases", profile: p)
        do {
            try policy.authorize(tool: "execute_query", profile: p)
            Issue.record("Scoped query was authorized without selecting a database")
        } catch let failure as MCPFailure {
            #expect(failure.code == .accessDenied)
            #expect(failure.message.contains("list_databases"))
        }
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "execute_query", profile: p, database: "private") }
        let sql = driver == .postgresql ? "SELECT CURRENT_DATABASE(), VERSION()" : "SELECT DATABASE(), VERSION()"
        await #expect(throws: MCPFailure.self) {
            _ = try await MCPSQLAuthorization.statements(sql, profile: p, database: "private", policy: policy)
        }
        do {
            _ = try await MCPSQLAuthorization.statements("SHOW DATABASES", profile: p, database: "allowed", policy: policy)
            Issue.record("Scoped SHOW was authorized without filtering metadata")
        } catch let failure as MCPFailure {
            #expect(failure.code == .accessDenied)
            #expect(failure.message.contains("list_databases"))
        }
    }
    @Test func argumentsRejectMixedArraysAndUnknownFields() throws {
        #expect(throws: MCPFailure.self) {
            try MCPToolCatalog.validate("execute_redis_command", arguments: ["connection_id": "id", "arguments": .array(["SET", .int(1), "value"])])
        }
        #expect(throws: MCPFailure.self) { try MCPToolCatalog.validate("list_connections", arguments: ["password": "secret"]) }
        #expect(throws: MCPFailure.self) { try MCPToolCatalog.validate("peek_messages", arguments: ["connection_id": "id", "topic": "a", "partition": .int(Int.max)]) }
    }
    @Test func defaultRedisDatabaseAndObjectScopesAreEnforced() throws {
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let redis = profile(type: .redis)
        policy.connections[redis.id.uuidString] = .init(databases: ["1"])
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "execute_redis_command", profile: redis) }
        for type in [DatabaseType.kafka, .elasticsearch] {
            let p = profile(type: type); policy.connections[p.id.uuidString] = .init(databases: ["allowed"])
            #expect(policy.permitsObject("allowed", profile: p))
            #expect(!policy.permitsObject("private", profile: p))
        }
    }
    @Test(arguments: ["DELETE FROM t WHERE 1=1", "DELETE FROM t WHERE id=id", "DELETE FROM t WHERE id=1 OR TRUE", "DELETE FROM t WHERE id=1 /* bypass */ OR 1=1"])
    func dataWriteRejectsIneffectiveFilters(_ sql: String) async throws {
        let p = profile(); var policy = MCPPolicy(); policy.connections[p.id.uuidString] = .init(mode: .dataWrite)
        await #expect(throws: (any Error).self) { _ = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy) }
    }
    @Test func dataWriteAllowsConcreteFilter() async throws {
        let p = profile(); var policy = MCPPolicy(); policy.connections[p.id.uuidString] = .init(mode: .dataWrite)
        let statements = try await MCPSQLAuthorization.statements("UPDATE users SET name='test' WHERE id=42 AND tenant_id=7", profile: p, database: "allowed", policy: policy)
        #expect(statements.count == 1)
    }
    @Test(arguments: ["SELECT evil_function()", "SELECT LOAD_FILE('/etc/passwd')", "WITH x AS (DELETE FROM users RETURNING *) SELECT * FROM x", "EXPLAIN ANALYZE DELETE FROM users", "SELECT 1 /*!; DELETE FROM users */"])
    func readonlyRejectsHiddenEffects(_ sql: String) async throws {
        await #expect(throws: (any Error).self) { _ = try await MCPSQLAuthorization.statements(sql, profile: profile(), database: "allowed", policy: MCPPolicy()) }
    }
    @Test func scopedRESTRejectsEncodedLookupsAndPipelines() throws {
        let escapedLookup = #"{"query":{"terms":{"user":{"ind\u0065x":"secret","id":"1","path":"users"}}}}"#
        for request in [
            WorkspaceRequest(method: .post, path: "/allowed/_search", body: Data(escapedLookup.utf8)),
            WorkspaceRequest(method: .put, path: "/allowed/_doc/1?pipeline=private", body: nil),
            WorkspaceRequest(method: .get, path: "/allowed%2F..%2Fsecret/_search", body: nil),
            WorkspaceRequest(method: .get, path: "/secret/_search", body: nil)
        ] {
            #expect(throws: (any Error).self) { try MCPRequestAuthorization.validate(request, allowed: ["allowed"]) }
        }
        try MCPRequestAuthorization.validate(.init(method: .post, path: "/allowed/_search?size=10", body: Data(#"{"query":{"match_all":{}}}"#.utf8)), allowed: ["allowed"])
    }
    @Test func processRunnerDrainsLargeOutputAndTimesOut() async throws {
        let output = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "200000", "/dev/zero"])
        #expect(output.utf8.count == 200000)
        await #expect(throws: MCPFailure.self) {
            _ = try await MCPProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        }
    }
    @Test func authorizerProcessPreservesTypedCredentialRecovery() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: script) }
        for code in [MCPFailureCode.credentialCancelled, .credentialDenied, .credentialUnavailable] {
            let text = "#!/bin/sh\nprintf '%s' '{\"credential_error\":\"\(code.rawValue)\"}'\nexit 1\n"
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            do {
                _ = try await MCPProcess.run(script, arguments: ["--authorize-credentials"])
                Issue.record("Failed authorizer unexpectedly succeeded")
            } catch let error as MCPFailure {
                #expect(error.code == code)
                #expect(error.message.contains("钥匙串") || error.message.contains("授权") || error.message.contains("Authorize saved credentials"))
            }
        }
    }

    @Test func pluginDispatchCannotBypassDisabledToolsOrSwitchConnections() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.disabledTools.insert("execute_query"); try MCPPolicyStore(directory: directory).save(policy)
        let runtime = MCPRuntime(directory: directory, registry: DatabaseDriverRegistry(drivers: [MCPTestDriver()]))
        let p = profile(); try await runtime.repository.insert(p)
        let result = try await runtime.call("querycraft_plugin_tools", arguments: ["connection_id": .string(p.id.uuidString)])
        #expect(result.arrayValue?.contains { $0.objectValue?["name"] == "execute_query" } == false)
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": .string(p.id.uuidString), "tool": "execute_query", "arguments": .object(["sql": "SELECT 1"])])
        }
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": .string(p.id.uuidString), "tool": "list_tables", "arguments": .object(["connection_id": .string(UUID().uuidString)])])
        }
        await runtime.shutdown()
    }
    @Test func destructiveSQLRequiresExplicitConfirmationBeforeDriverInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: directory).save(policy)
        let runtime = MCPRuntime(directory: directory)
        let p = profile(); policy.connections[p.id.uuidString] = .init(mode: .fullAccess)
        do {
            _ = try await runtime.execute("execute_query", args: ["sql": "DROP TABLE users"], profile: p, database: "allowed",
                connection: UnavailableDatabaseWorkspaceSession(error: MCPFailure("driver invoked")), policy: policy, inTransaction: false)
            Issue.record("Destructive SQL should require explicit confirmation")
        } catch let error as MCPFailure { #expect(error.message.contains("confirm_high_risk")) }
        await runtime.shutdown()
    }

}

private struct MCPTestDriver: DatabaseDriver {
    let databaseType: DatabaseType = .mysql
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession {
        UnavailableDatabaseWorkspaceSession(error: MCPFailure("Test does not connect to databases"))
    }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws { throw MCPFailure("unused") }
}
