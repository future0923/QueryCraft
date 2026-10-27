import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPAuthorizationMatrixTests {
    private let modes: [MCPExecutionMode?] = [nil, .readOnly, .dataWrite, .fullAccess]

    @Test(arguments: DatabaseType.allCases)
    func everyGrantInheritanceScopeAndToolCombination(_ type: DatabaseType) throws {
        let group = UUID(), profile = MCPTests().profile(type: type, group: group)
        var checked = 0
        for groupMode in modes { for connectionMode in modes { for objectMode in modes {
            for grants in 0..<8 { for enabled in [false, true] { for scope in 0..<5 { for disabled in [false, true] {
                var policy = MCPPolicy(); policy.enabled = enabled
                policy.allConnections = grants & 1 != 0
                if grants & 2 != 0 { policy.groupIDs = [group] }
                if grants & 4 != 0 { policy.connectionIDs = [profile.id] }
                policy.groupModes[group.uuidString] = groupMode
                let names: Set<String>? = scope == 0 ? nil : scope == 1 ? ["allowed"] : scope == 2 ? ["other"] : []
                policy.connections[profile.id.uuidString] = .init(databases: names, mode: connectionMode,
                    databaseModes: objectMode.map { ["allowed": $0] } ?? [:], databaseAccess: scope == 4 ? MCPDatabaseAccess.none : scope == 0 ? .all : .selected)
                if disabled { policy.disabledTools = ["list_tables"] }
                let effective = objectMode ?? connectionMode ?? groupMode ?? .readOnly
                #expect(policy.effectiveMode(profile, database: "allowed") == effective)
                let scopedNameAllowed = scope == 0 || scope == 1 || (scope == 2 && [.elasticsearch, .kafka].contains(type))
                let expected = enabled && grants != 0 && !disabled && scopedNameAllowed
                do {
                    try policy.authorize(tool: "list_tables", profile: profile, database: "allowed")
                    #expect(expected, "Unexpected grant: driver=\(type), scope=\(scope), grants=\(grants), enabled=\(enabled), disabled=\(disabled)")
                } catch let failure as MCPFailure {
                    #expect(expected == false)
                    #expect(failure.code == .accessDenied)
                }
                checked += 1
            } } } }
        } } }
        #expect(checked == 10_240)
        print("MCP_MATRIX grant/inheritance/scope/tool \(type.rawValue): \(checked)")
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], MCPExecutionMode.allCases)
    func sqlOperationsRespectObjectAccessWithBothScopes(_ type: DatabaseType, _ mode: MCPExecutionMode) async throws {
        let p = MCPTests().profile(type: type)
        let operations: [(String, Int, Bool)] = [
            ("SELECT 1", 0, false),
            ("SELECT VERSION(), ABS(1)", 0, false),
            ("SELECT 'LOAD_FILE /* not executable */'", 0, false),
            ("INSERT INTO users (id) VALUES (1)", 1, false),
            ("UPDATE users SET name='value' WHERE id=1", 1, false),
            ("DELETE FROM users WHERE id=1 AND tenant_id=7", 1, false),
            ("UPDATE users SET name='value'", 2, true),
            ("DELETE FROM users", 2, true),
            ("CREATE TABLE users (id INT)", 2, true),
            ("ALTER TABLE users ADD COLUMN name VARCHAR(20)", 2, true),
            ("CREATE INDEX idx ON users(id)", 2, true),
            ("DROP INDEX idx ON users", 2, true),
            ("ALTER TABLE users RENAME TO renamed", 2, true),
            ("TRUNCATE TABLE users", 2, true),
            ("DROP TABLE users", 2, true)
        ]
        let level = mode == .readOnly ? 0 : mode == .dataWrite ? 1 : 2
        for scoped in [false, true] {
            var policy = MCPPolicy()
            policy.connections[p.id.uuidString] = .init(databases: scoped ? ["allowed"] : nil, mode: .readOnly, databaseModes: ["allowed": mode])
            for (sql, required, confirm) in operations {
                do {
                    let statements = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
                    #expect(level >= required, "Unexpected SQL grant: \(type) \(mode) scoped=\(scoped) \(sql)")
                    #expect(statements.count == 1)
                    #expect(statements.first?.requiresConfirmation == confirm)
                } catch let failure as MCPFailure {
                    #expect(level < required, "Unexpected SQL denial: \(type) \(mode) scoped=\(scoped) \(sql): \(failure)")
                    #expect(failure.code == .accessDenied)
                }
            }
        }
        print("MCP_MATRIX SQL authorization \(type.rawValue) \(mode.rawValue): \(operations.count * 2)")
    }

    @Test(arguments: [DatabaseType.mysql, .doris], MCPExecutionMode.allCases)
    func explicitWriteTargetsUseTheirOwnModes(_ type: DatabaseType, _ targetMode: MCPExecutionMode) async throws {
        let p = MCPTests().profile(type: type)
        for scoped in [false, true] {
            var policy = MCPPolicy()
            policy.connections[p.id.uuidString] = .init(databases: scoped ? ["allowed", "target"] : nil, mode: .fullAccess,
                databaseModes: ["allowed": .readOnly, "target": targetMode])
            for sql in ["INSERT INTO target.users(id) VALUES (1)", "UPDATE target.users SET name='x' WHERE id=1", "DELETE FROM target.users WHERE id=1"] {
                do {
                    let statements = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
                    #expect(targetMode != .readOnly)
                    #expect(statements.first?.writesData == true)
                } catch let error as MCPFailure {
                    #expect(targetMode == .readOnly, "Unexpected target denial: \(sql) \(error)")
                    #expect(error.code == .accessDenied)
                }
            }
        }
    }

    @Test(arguments: [DatabaseType.mysql, .doris])
    func restrictedTargetsCannotEscapeThroughDMLDDLOrFunctions(_ type: DatabaseType) async throws {
        let p = MCPTests().profile(type: type)
        var policy = MCPPolicy()
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .fullAccess)
        for sql in ["SELECT * FROM private.users", "INSERT INTO private.users(id) VALUES (1)", "DELETE FROM private.users WHERE id=1",
                    "UPDATE private.users SET id=2 WHERE id=1", "CREATE TABLE private.users(id INT)", "ALTER TABLE private.users ADD COLUMN name INT",
                    "DROP TABLE private.users", "TRUNCATE TABLE private.users", "CREATE INDEX idx ON private.users(id)",
                    "ALTER TABLE allowed.users RENAME TO private.users", "CREATE VIEW allowed.v AS SELECT * FROM private.users", "SELECT private.custom_function()"] {
            do {
                _ = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
                Issue.record("Cross-scope SQL was authorized: \(sql)")
            } catch let error as MCPFailure { #expect(error.code == .accessDenied) }
        }
    }

    @Test(arguments: [DatabaseType.redis, .elasticsearch, .kafka], MCPExecutionMode.allCases)
    func nonSQLWriteConfirmationScopeOverridesAndBothRoutes(_ type: DatabaseType, _ mode: MCPExecutionMode) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = MCPTests().profile(type: type), session = PermissionDriverSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: type, session: session)]))
        try await runtime.repository.insert(p)
        let target = type == .redis ? "0" : "allowed"
        let operations: [(String, [String: MCPJSONValue], Int, Bool)]
        if type == .redis {
            operations = [("execute_redis_command", ["database": "0", "arguments": .array(["GET", "fixture"])], 0, false),
                          ("execute_redis_command", ["database": "0", "arguments": .array(["SET", "fixture", "value"])], 1, false),
                          ("execute_redis_command", ["database": "0", "arguments": .array(["FLUSHDB"])], 2, true)]
        } else if type == .elasticsearch {
            operations = [("execute_request", ["method": "POST", "path": "/allowed/_search", "body": "{\"query\":{\"match_all\":{}}}"], 0, false),
                          ("execute_request", ["method": "PUT", "path": "/allowed/_doc/1", "body": "{\"index\":\"field\",\"script\":\"data\",\"pipeline\":\"data\"}"], 1, false),
                          ("execute_request", ["method": "PUT", "path": "/allowed", "body": "{}"], 2, true),
                          ("execute_request", ["method": "DELETE", "path": "/allowed"], 2, true),
                          ("execute_request", ["method": "PUT", "path": "/allowed/_mapping", "body": "{\"properties\":{\"index\":{\"type\":\"keyword\"}}}"], 2, true)]
        } else {
            operations = [("send_message", ["topic": "allowed", "value": "fixture"], 1, false)]
        }
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
        let store = MCPPolicyStore(directory: root)
        let level = mode == .readOnly ? 0 : mode == .dataWrite ? 1 : 2
        var checked = 0
        for scoped in [false, true] { for disabled in [false, true] { for confirm in [false, true] { for delegated in [false, true] {
            policy.connections[p.id.uuidString] = .init(databases: scoped ? [target] : nil, mode: .readOnly, databaseModes: [target: mode])
            for (tool, extra, needed, dangerous) in operations {
                policy.disabledTools = disabled ? [tool] : []
                try store.save(policy)
                var args = extra; args["connection_id"] = .string(p.id.uuidString)
                if tool != "send_message" { args["confirm_high_risk"] = .bool(confirm) }
                let before = await session.writes
                let expected = !disabled && level >= needed && (!dangerous || confirm)
                do {
                    if delegated {
                        _ = try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": .string(p.id.uuidString), "tool": .string(tool), "arguments": .object(args)])
                    } else { _ = try await runtime.call("querycraft_" + tool, arguments: args) }
                    #expect(expected, "Unexpected grant: \(type) \(mode) \(tool) \(extra)")
                    #expect(await session.writes == before + 1)
                } catch let failure as MCPFailure {
                    #expect(expected == false, "Unexpected denial: \(type) \(mode) \(tool): \(failure)")
                    #expect(failure.code == (disabled || level < needed ? .accessDenied : .confirmationRequired))
                    #expect(await session.writes == before)
                }
                checked += 1
            }
        } } } }
        print("MCP_MATRIX non-SQL runtime \(type.rawValue) \(mode.rawValue): \(checked)")
        await runtime.shutdown()
    }

    @Test func globalOperationsCannotBypassReadOnlyObjectOverrides() async throws {
        let redis = MCPTests().profile(type: .redis), es = MCPTests().profile(type: .elasticsearch)
        var policy = MCPPolicy()
        policy.connections[redis.id.uuidString] = .init(mode: .fullAccess, databaseModes: ["1": .readOnly])
        #expect(policy.permitsAllObjectWrites(redis) == false)
        policy.connections[es.id.uuidString] = .init(mode: .fullAccess, databaseModes: ["ro": .readOnly])
        let args: [String: MCPJSONValue] = ["method": "DELETE", "path": "/full,ro"]
        #expect(try policy.executionMode(es, database: nil, args: args) == .readOnly)
        #expect(throws: MCPFailure.self) { _ = try policy.executionMode(es, database: nil, args: ["method": "DELETE", "path": "/*"]) }
        let bulk = "{\"index\":{\"_index\":\"ro\"}}\n{\"index\":\"ordinary field\"}\n"
        #expect(try policy.executionMode(es, database: nil, args: ["method": "POST", "path": "/full/_bulk", "body": .string(bulk)]) == .readOnly)
        policy.connections[redis.id.uuidString]?.databaseModes["1"] = .fullAccess
        #expect(policy.permitsAllObjectWrites(redis))
        #expect(try policy.executionMode(es, database: nil, args: ["method": "PUT", "path": "/full", "body": "{\"aliases\":{\"ro\":{}}}"]) == .readOnly)
        _ = try policy.executionMode(es, database: nil, args: ["method": "POST", "path": "/_search", "body": "{\"query\":{\"match_all\":{}}}"])
        policy.connections[es.id.uuidString]?.databaseModes["ro"] = .fullAccess
        #expect(try policy.executionMode(es, database: nil, args: ["method": "DELETE", "path": "/*"]) == .fullAccess)
    }

    @Test func searchAndBatchLookupValidationDoesNotTreatDocumentFieldsAsTargets() throws {
        let es = MCPTests().profile(type: .elasticsearch)
        let globalSearch: [String: MCPJSONValue] = ["method": "POST", "path": "/_msearch", "body": "{}\n{\"query\":{\"match_all\":{}}}\n"]
        var policy = MCPPolicy()
        #expect(try policy.executionMode(es, database: nil, args: globalSearch) == .readOnly)
        policy.connections[es.id.uuidString] = .init(databases: ["allowed"], mode: .fullAccess)
        #expect(throws: MCPFailure.self) { _ = try policy.executionMode(es, database: nil, args: globalSearch) }
        for path in ["/allowed/_search", "/allowed/_msearch"] {
            let query = "{\"query\":{\"terms\":{\"field\":{\"index\":\"private\",\"id\":\"1\",\"path\":\"values\"}}}}"
            let body = path.hasSuffix("_msearch") ? "{}\n" + query + "\n" : query
            #expect(throws: MCPFailure.self) { try MCPRequestAuthorization.validate(.init(method: .post, path: path, body: Data(body.utf8)), allowed: ["allowed"]) }
        }
        for field in ["index", "script", "pipeline", "indices", "percolate"] {
            let body = Data("{\"query\":{\"term\":{\"\(field)\":\"ordinary value\"}}}".utf8)
            try MCPRequestAuthorization.validate(.init(method: .post, path: "/allowed/_search", body: body), allowed: ["allowed"])
        }
        try MCPRequestAuthorization.validate(.init(method: .put, path: "/allowed/_settings", body: Data("{\"settings\":{\"index.default_pipeline\":\"_none\"}}".utf8)), allowed: ["allowed"])
    }

    @Test func postgresCatalogFunctionsAndSelectedDatabaseSchemaDDL() async throws {
        let p = MCPTests().profile(type: .postgresql)
        var policy = MCPPolicy()
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .readOnly)
        _ = try await MCPSQLAuthorization.statements("SELECT pg_catalog.version(), pg_catalog.current_database()", profile: p, database: "allowed", policy: policy)
        policy.connections[p.id.uuidString]?.databaseModes["allowed"] = .fullAccess
        for sql in ["CREATE SCHEMA fixture", "CREATE TABLE fixture.t(id INT)", "COMMENT ON COLUMN fixture.t.id IS 'comment'", "DROP SCHEMA fixture CASCADE"] {
            let statements = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
            #expect(statements.first?.requiresConfirmation == true)
        }
    }

    @Test func dorisCommentOnlyDDLAndMultipleDropTargetsUseTheSameScopeRules() async throws {
        let p = MCPTests().profile(type: .doris)
        var policy = MCPPolicy()
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .fullAccess)
        for sql in ["ALTER TABLE allowed.t MODIFY COLUMN note COMMENT 'scope comment'", "ALTER TABLE allowed.t MODIFY COMMENT 'table comment'", "DROP TABLE allowed.t, allowed.u"] {
            let statements = try await MCPSQLAuthorization.statements(sql, profile: p, database: "allowed", policy: policy)
            #expect(statements.count == 1)
            #expect(statements.first?.requiresConfirmation == true)
        }
        do {
            _ = try await MCPSQLAuthorization.statements("DROP TABLE allowed.t, private.u", profile: p, database: "allowed", policy: policy)
            Issue.record("One authorized DROP target granted access to another database")
        } catch let error as MCPFailure { #expect(error.code == .accessDenied) }
    }

    @Test func advertisedAccessIncludesOverridesWithoutGrantingOutOfScopeObjects() {
        let p = MCPTests().profile()
        var policy = MCPPolicy()
        policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .readOnly, databaseModes: ["allowed": .fullAccess, "private": .fullAccess])
        let access = policy.accessMetadata(p).objectValue
        #expect(access?["default_mode"] == "read_only")
        #expect(access?["allowed_databases"] == .array(["allowed"]))
        #expect(access?["object_modes"]?.objectValue == ["allowed": "high_risk_write"])
    }

    @Test(arguments: DatabaseType.allCases)
    func scopedLazyDiscoveryDoesNotRequireAnUnrelatedDefaultDatabase(_ type: DatabaseType) async throws {
        let p = MCPTests().profile(type: type)
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
        policy.connections[p.id.uuidString] = .init(databases: ["selected"], mode: .fullAccess)
        try policy.authorize(tool: "plugin_tools", profile: p)
        try policy.authorize(tool: "plugin_call", profile: p)
        try policy.authorize(tool: "list_databases", profile: p, database: "unselected_default")
        policy.connections[p.id.uuidString]?.databaseAccess = MCPDatabaseAccess.none
        try policy.authorize(tool: "plugin_tools", profile: p)
        #expect(throws: MCPFailure.self) { try policy.authorize(tool: "list_tables", profile: p, database: "selected") }
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris])
    func realDiscoveryRouteAvoidsAnUnselectedSavedDefault(_ type: DatabaseType) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = MCPTests().profile(type: type), session = PermissionDriverSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: type, session: session)]))
        try await runtime.repository.insert(p)
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
        policy.connections[p.id.uuidString] = .init(databases: ["permitted"], mode: .readOnly)
        try MCPPolicyStore(directory: root).save(policy)
        let tools = try await runtime.call("querycraft_plugin_tools", arguments: ["connection_id": .string(p.id.uuidString)])
        #expect(tools.arrayValue?.isEmpty == false)
        _ = try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": .string(p.id.uuidString), "tool": "list_databases", "arguments": .object([:])])
        let configured = await session.configuredDatabases
        try #require(configured.isEmpty == false)
        #expect(configured[0] == (type == .postgresql ? "permitted" : nil))
        await runtime.shutdown()
    }

    @Test func redisDisplayNamesAndNumericNamesShareOnePermissionIdentity() async throws {
        let p = MCPTests().profile(type: .redis)
        let names = ["8", "08", "DB 8", "db 8", " DB 8 "]
        var checked = 0
        for stored in names { for supplied in names { for mode in MCPExecutionMode.allCases { for scoped in [false, true] {
            var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
            policy.connections[p.id.uuidString] = .init(databases: scoped ? [stored] : nil, mode: .readOnly, databaseModes: [stored: mode])
            try policy.authorize(tool: "execute_redis_command", profile: p, database: supplied)
            #expect(policy.effectiveMode(p, database: supplied) == mode)
            #expect(policy.permitsDatabaseName(supplied, profile: p))
            #expect(policy.accessMetadata(p).objectValue?["object_modes"]?.objectValue?["8"] == .string(mode.rawValue))
            checked += 1
        } } } }
        #expect(checked == 150)
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
        policy.connections[p.id.uuidString] = .init(databases: ["DB 8"], mode: .fullAccess, databaseModes: ["8": .fullAccess, "DB 8": .readOnly])
        for name in names { #expect(policy.effectiveMode(p, database: name) == .readOnly) }
        print("MCP_MATRIX Redis name aliases: \(checked)")
    }

    @Test func redisRuntimeUsesSavedDisplayNameAndFiltersNumericGrants() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = ConnectionProfile(id: UUID(), name: "Redis", groupID: nil, databaseType: .redis, host: "localhost", port: 6379,
            username: "", defaultDatabase: "DB 8", tlsMode: .disabled, storesCredential: false, createdAt: Date())
        let session = PermissionDriverSession(), runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: .redis, session: session)]))
        try await runtime.repository.insert(p)
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
        policy.connections[p.id.uuidString] = .init(databases: ["8"], mode: .fullAccess)
        try MCPPolicyStore(directory: root).save(policy)
        _ = try await runtime.call("querycraft_execute_redis_command", arguments: ["connection_id": .string(p.id.uuidString), "arguments": .array(["SET", "fixture", "value"])])
        #expect(await session.redisDatabases == [8])
        let names = try await runtime.call("querycraft_list_databases", arguments: ["connection_id": .string(p.id.uuidString)])
        #expect(names == .array(["DB 8"]))
        await runtime.shutdown()
    }

    @Test(arguments: DatabaseType.allCases)
    func fullAccessCannotTurnAnotherDriverProtocolIntoACapability(_ type: DatabaseType) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = MCPTests().profile(type: type), session = PermissionDriverSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: type, session: session)]))
        try await runtime.repository.insert(p)
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        policy.connections[p.id.uuidString] = .init(mode: .fullAccess)
        try MCPPolicyStore(directory: root).save(policy)
        let tools: [(String, [String: MCPJSONValue], Bool)] = [
            ("execute_query", ["sql": "SELECT 1"], [.mysql, .postgresql, .doris].contains(type)),
            ("open_session", [:], [.mysql, .postgresql, .doris].contains(type)),
            ("execute_redis_command", ["arguments": .array(["PING"])], type == .redis),
            ("execute_request", ["method": "GET", "path": "/"], type == .elasticsearch),
            ("send_message", ["topic": "allowed", "value": "fixture"], type == .kafka)]
        for (tool, extra, supported) in tools where !supported {
            do {
                _ = try await runtime.call("querycraft_" + tool, arguments: extra.merging(["connection_id": .string(p.id.uuidString)]) { _, value in value })
                Issue.record("Wrong driver protocol was accepted: \(type) \(tool)")
            } catch let failure as MCPFailure { #expect(failure.code == .unsupported) }
        }
        #expect(await session.statements.isEmpty)
        #expect(await session.writes == 0)
        await runtime.shutdown()
    }

    @Test func everySSHGrantBitAndToolCombination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPRuntime(directory: root)
        let p = SSHConnection(id: UUID(), name: "fixture", host: "127.0.0.1", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), storesCredential: false)
        for bits in 0..<32 { for enabled in [false, true] { for disabled in [false, true] {
            for tool in MCPToolCatalog.sshTools {
                var policy = MCPPolicy(); policy.enabled = enabled; policy.allConnections = true
                policy.ssh = .init(connectionIDs: bits & 1 != 0 ? [p.id] : [], executionConnectionIDs: bits & 2 != 0 ? [p.id] : [],
                    fileReadConnectionIDs: bits & 4 != 0 ? [p.id] : [], fileTransferConnectionIDs: bits & 8 != 0 ? [p.id] : [],
                    fileManagementConnectionIDs: bits & 16 != 0 ? [p.id] : [])
                if disabled { policy.disabledTools = [tool] }
                let required: Int
                if MCPToolCatalog.sshFileWrites.contains(tool) { required = 1 | 16 }
                else if MCPToolCatalog.sshRecoveryReads.union(MCPToolCatalog.sshRecoveryWrites).contains(tool) { required = 1 | 8 }
                else if MCPToolCatalog.sshFileReads.contains(tool) { required = 1 | 4 }
                else if MCPToolCatalog.sshTransfers.contains(tool) { required = tool == "ssh_download_file" ? 1 | 4 | 8 : 1 | 8 }
                else if MCPToolCatalog.sshTaskReads.union(MCPToolCatalog.sshTaskWrites).contains(tool) || tool == "ssh_execute" { required = 1 | 2 }
                else { required = 1 }
                #expect(await runtime.sshPermitted(p, tool: tool, policy: policy) == (enabled && !disabled && bits & required == required))
            }
        } } }
        print("MCP_MATRIX SSH grant/tool: \(32 * 2 * 2 * MCPToolCatalog.sshTools.count)")
        await runtime.shutdown()
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris], MCPExecutionMode.allCases)
    func sqlRuntimeModesConfirmationsDisabledToolsAndDelegation(_ type: DatabaseType, _ mode: MCPExecutionMode) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = MCPTests().profile(type: type), session = PermissionDriverSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: type, session: session)]))
        try await runtime.repository.insert(p)
        let operations: [(String, Int, Bool)] = [("SELECT VERSION()", 0, false), ("INSERT INTO t(id) VALUES(1)", 1, false),
            ("UPDATE t SET id=2 WHERE id=1", 1, false), ("DELETE FROM t WHERE id=1", 1, false),
            ("UPDATE t SET id=2", 2, true), ("CREATE TABLE t(id INT)", 2, true),
            ("ALTER TABLE t ADD COLUMN name INT", 2, true), ("DROP TABLE t", 2, true)]
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [p.id]
        let store = MCPPolicyStore(directory: root)
        let level = mode == .readOnly ? 0 : mode == .dataWrite ? 1 : 2
        var checked = 0
        for scoped in [false, true] { for confirm in [false, true] { for disabled in [false, true] { for delegated in [false, true] {
            policy.connections[p.id.uuidString] = .init(databases: scoped ? ["allowed"] : nil, mode: mode)
            for tool in ["execute_query", "execute_batch"] { for (sql, required, dangerous) in operations {
                policy.disabledTools = disabled ? [tool] : []; try store.save(policy)
                let args: [String: MCPJSONValue] = ["connection_id": .string(p.id.uuidString), "database": "allowed", "sql": .string(sql), "confirm_high_risk": .bool(confirm)]
                let before = await session.statements.filter { $0 == sql }.count
                let expected = !disabled && level >= required && (!dangerous || confirm)
                do {
                    if delegated {
                        _ = try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": .string(p.id.uuidString), "tool": .string(tool), "arguments": .object(args)])
                    } else { _ = try await runtime.call("querycraft_" + tool, arguments: args) }
                    #expect(expected, "Unexpected runtime grant: \(type) \(mode) \(sql)")
                    #expect(await session.statements.filter { $0 == sql }.count == before + 1)
                } catch let failure as MCPFailure {
                    #expect(expected == false, "Unexpected runtime denial: \(type) \(mode) \(sql): \(failure)")
                    #expect(failure.code == (disabled || level < required ? .accessDenied : .confirmationRequired))
                    #expect(await session.statements.filter { $0 == sql }.count == before)
                }
                checked += 1
            } }
        } } } }
        #expect(checked == 256)
        print("MCP_MATRIX SQL runtime \(type.rawValue) \(mode.rawValue): \(checked)")
        await runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func batchStopsAfterObjectRevocationOrConnectionRemoval(_ removeConnection: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = MCPTests().profile(), session = PermissionDriverSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [PermissionDriver(databaseType: .mysql, session: session)]))
        try await runtime.repository.insert(p)
        var initial = MCPPolicy(); initial.enabled = true; initial.connectionIDs = [p.id]
        initial.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .fullAccess)
        let store = MCPPolicyStore(directory: root); try store.save(initial)
        var revoked = initial; revoked.connections[p.id.uuidString]?.databaseModes["allowed"] = .readOnly
        let nextPolicy = revoked
        await session.setStatementHook { sql in
            if sql == "INSERT INTO t(id) VALUES(1);" {
                if removeConnection { try await runtime.repository.delete(id: p.id) }
                else { try store.save(nextPolicy) }
            }
        }
        do {
            _ = try await runtime.call("querycraft_execute_batch", arguments: ["connection_id": .string(p.id.uuidString), "database": "allowed", "sql": "INSERT INTO t(id) VALUES(1); INSERT INTO t(id) VALUES(2)"])
            Issue.record("Batch continued after revocation/removal")
        } catch let error as MCPFailure { #expect(error.code == (removeConnection ? .connectionNotFound : .accessDenied)) }
        #expect(await session.statements == ["INSERT INTO t(id) VALUES(1);"])
        await runtime.shutdown()
    }
}
