import Foundation
import MCP

actor MCPRuntime {
    struct Session: Sendable {
        let id: String
        let profile: ConnectionProfile
        let database: String?
        let connection: any WorkspaceSession
        var lastUsed = Date()
        var busy = false
        var transaction = false
        let mode: MCPExecutionMode
    }
    let serverIdentity: MCPServerIdentity
    let store: MCPPolicyStore
    let repository: SQLiteConnectionProfileRepository
    let credentials: any CredentialStore
    let registry: DatabaseDriverRegistry
    var sessions: [String: Session] = [:]
    var pendingConnections = 0
    var metadataCache: [String: MetadataCacheEntry] = [:]
    var metadataGeneration: UInt64 = 0
    var idleConnections: [IdleConnection] = []
    let history: MCPHistoryStore
    var stopped = false
    private var maintenance: Task<Void, Never>?

    init(directory: URL, credentials: (any CredentialStore)? = nil, registry: DatabaseDriverRegistry = .shared) {
        serverIdentity = MCPServerIdentity(directory: directory)
        store = MCPPolicyStore(directory: directory)
        history = MCPHistoryStore(directory: directory)
        repository = SQLiteConnectionProfileRepository(databaseURL: directory.appending(path: "QueryCraft.sqlite"))
        self.credentials = credentials ?? MCPCredentialStore(directory: directory); self.registry = registry
    }

    func startMaintenance() {
        guard maintenance == nil else { return }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.maintainSessions()
            }
        }
    }
    private func maintainSessions() async {
        let policy = try? store.load()
        await retireIdleConnections(policy: policy)
        let invalid = sessions.values.filter { entry in
            guard !entry.busy else { return false }
            guard let policy else { return true }
            return !policy.permits(entry.profile) || Date().timeIntervalSince(entry.lastUsed) >= Double(policy.sessionIdleSeconds)
        }
        for entry in invalid { sessions.removeValue(forKey: entry.id) }
        for entry in invalid { await entry.connection.close() }
    }
    deinit { maintenance?.cancel() }

    func tools() throws -> [Tool] {
        let policy = try store.load()
        guard policy.enabled else { return [] }
        return MCPToolCatalog.definitions.filter {
            guard !policy.disabledTools.contains($0.name) else { return false }
            switch policy.tuning.discovery {
            case .both: return true
            case .flat: return !MCPToolCatalog.metaTools.contains($0.name)
            case .lazy: return ["list_connections", "plugin_list", "plugin_tools", "plugin_call", "close_session", "rollback_transaction", "add_connection", "duplicate_connection", "remove_connection", "open_table", "execute_and_show"].contains($0.name)
            }
        }.map(\.tool)
    }

    func call(_ name: String, arguments args: [String: Value]) async throws -> Value {
        let started = Date()
        let recordsHistory = (try? store.load().tuning.recordsHistory) == true
        let known = MCPToolCatalog.definitions.contains { "querycraft_" + $0.name == name }
        let tool = known ? name : "unknown_tool"
        let connectionID = args.string("connection_id").flatMap(UUID.init(uuidString:))?.uuidString
            ?? args.string("session_id").flatMap { sessions[$0]?.profile.id.uuidString }
        do {
            let result = try await dispatch(name, arguments: args)
            let bytes = try JSONEncoder().encode(result).count
            guard bytes <= ((try? store.load().maximumResultBytes) ?? 4_194_304) else {
                throw MCPFailure("Result exceeds the configured limit. The operation may have completed.", code: .resultTooLarge)
            }
            if recordsHistory {
                let partial = result.objectValue?["results"]?.arrayValue?.contains { $0.objectValue?["error"] != nil } == true
                try? await history.append(.init(id: UUID().uuidString, startedAt: started, tool: tool, connectionID: connectionID,
                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), succeeded: !partial,
                    errorCode: partial ? "PARTIAL_FAILURE" : nil, resultBytes: bytes))
            }
            return result
        } catch {
            if recordsHistory {
                try? await history.append(.init(id: UUID().uuidString, startedAt: started, tool: tool, connectionID: connectionID,
                    durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), succeeded: false,
                    errorCode: MCPFailure.normalized(error).code.rawValue, resultBytes: 0))
            }
            throw error
        }
    }

    private func dispatch(_ name: String, arguments args: [String: Value]) async throws -> Value {
        guard name.hasPrefix("querycraft_"), MCPToolCatalog.definitions.contains(where: { "querycraft_" + $0.name == name }) else {
            throw MCPFailure("Unknown QueryCraft MCP tool.")
        }
        let tool = String(name.dropFirst("querycraft_".count))
        try MCPToolCatalog.validate(tool, arguments: args)
        // Revoking execution permissions must not prevent resource cleanup.
        if tool == "close_session" || tool == "rollback_transaction" {
            let id = try args.requiredString("session_id")
            guard var entry = sessions[id] else { throw MCPFailure("Session is closed or expired. Open a new session.", code: .sessionUnavailable) }
            guard !entry.busy else { throw MCPFailure("Session is busy.", code: .sessionBusy) }
            sessions[id]?.busy = true
            do {
                if entry.transaction { try await transaction(.rollback, entry: entry) }
                if tool == "close_session" { sessions.removeValue(forKey: id); await entry.connection.close() }
                else { guard !stopped, sessions[id] != nil else { throw MCPFailure("Session closed during rollback.") }; entry.transaction = false; entry.busy = false; entry.lastUsed = Date(); sessions[id] = entry }
                return .object(["status": .string(tool == "close_session" ? "closed" : "rolled_back")])
            } catch { sessions.removeValue(forKey: id); await entry.connection.close(); throw error }
        }
        guard !stopped else { throw MCPFailure("MCP runtime is shutting down.") }
        var policy = try store.load()
        await expireSessions(policy: policy)
        policy = try store.load()
        try policy.authorize(tool: tool)
        if tool == "list_connections" {
            let profiles = try await repository.fetchAll()
            var values: [Value] = []
            for p in profiles where policy.permits(p) {
                values.append(.object(["id": .string(p.id.uuidString), "name": .string(p.name), "type": .string(p.databaseType.rawValue),
                                       "host": .string(p.host), "port": .int(p.port), "database": p.defaultDatabase.map(Value.string) ?? .null,
                                       "driver_installed": .bool(await registry.isInstalled(p.databaseType))]))
            }
            return .array(values)
        }
        if tool == "plugin_list" {
            return .array(await registry.installedDatabaseTypes().sorted { $0.rawValue < $1.rawValue }.map {
                .object(["id": .string($0.rawValue), "name": .string($0.title), "tools": .array(MCPToolCatalog.driverTools($0).subtracting(policy.disabledTools).sorted().map(Value.string))])
            })
        }
        if tool == "add_connection" { return try await addConnection(args, policy: policy) }

        let id = args.string("session_id")
        let savedEntry = id.flatMap { sessions[$0] }
        // Reserve before the first suspension; actor isolation alone does not serialize calls.
        if let savedEntry {
            guard !savedEntry.busy else { throw MCPFailure("Session is busy. Wait for its current operation to finish.", code: .sessionBusy) }
            sessions[savedEntry.id]?.busy = true
        }
        defer { if let id { sessions[id]?.busy = false; sessions[id]?.lastUsed = Date() } }
        if id != nil && savedEntry == nil { throw MCPFailure("Session is closed or expired. Open a new session.", code: .sessionUnavailable) }
        let profile: ConnectionProfile
        if let savedEntry {
            guard !savedEntry.busy else { throw MCPFailure("Session is busy. Wait for its current operation to finish.", code: .sessionBusy) }
            if let requestedID = args.string("connection_id"), requestedID != savedEntry.profile.id.uuidString {
                throw MCPFailure("Session does not belong to the requested connection.")
            }
            guard let current = try await repository.fetch(id: savedEntry.profile.id) else { throw MCPFailure("Connection was removed.", code: .connectionNotFound) }
            guard current == savedEntry.profile else { throw MCPFailure("Connection changed. Close this session and open a new one.", code: .sessionUnavailable) }
            profile = current
        } else {
            guard let uuid = UUID(uuidString: try args.requiredString("connection_id")), let current = try await repository.fetch(id: uuid) else {
                throw MCPFailure("Connection not found.", code: .connectionNotFound)
            }
            profile = current
        }
        let database = args.string("database") ?? savedEntry?.database ?? profile.defaultDatabase
            ?? (profile.databaseType == .redis ? "0" : profile.databaseType == .kafka ? "Kafka" : nil)
        policy = try store.load()
        if let savedEntry, database != savedEntry.database { throw MCPFailure("Database cannot change on a pinned session. Open another session.") }
        try policy.authorize(tool: tool, profile: profile, database: database)
        if tool == "plugin_tools" || tool == "plugin_call" {
            guard await registry.isInstalled(profile.databaseType) else { throw MCPFailure("Install this connection driver first.", code: .unsupported) }
            let names = MCPToolCatalog.driverTools(profile.databaseType).subtracting(policy.disabledTools)
            if tool == "plugin_tools" {
                return .array(MCPToolCatalog.definitions.filter { names.contains($0.name) }.map {
                    .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.tool.inputSchema])
                })
            }
            let target = try args.requiredString("tool")
            guard names.contains(target), var delegated = args["arguments"]?.objectValue else { throw MCPFailure("Driver tool is not available.", code: .accessDenied) }
            if let supplied = delegated.string("connection_id"), supplied != profile.id.uuidString {
                throw MCPFailure("Driver calls cannot switch connections.", code: .accessDenied)
            }
            delegated["connection_id"] = .string(profile.id.uuidString)
            if delegated["database"] == nil, let database { delegated["database"] = .string(database) }
            return try await dispatch("querycraft_" + target, arguments: delegated)
        }
        if tool == "duplicate_connection" || tool == "remove_connection" {
            return try await mutateConnection(tool, profile: profile, args: args, policy: policy)
        }
        let accessTarget = profile.databaseType == .kafka ? args.string("topic")
            : profile.databaseType == .elasticsearch ? args.string("path").flatMap(MCPRequestAuthorization.index) : database
        let mode = policy.effectiveMode(profile, database: accessTarget)
        if let savedEntry, savedEntry.mode != mode { throw MCPFailure("Session permissions changed. Close and reopen the session.", code: .sessionUnavailable) }
        let metadataOnly = MCPToolCatalog.metadataTools.contains(tool) && savedEntry == nil
        let cacheKey = try metadataKey(tool: tool, args: args, profile: profile, database: database, policy: policy)
        if let cached = cachedMetadata(key: cacheKey, profile: profile, policy: policy, refresh: args.flag("refresh")) { return cached }
        let cacheGeneration = metadataGeneration
        var reservedConnection = false
        defer { if reservedConnection { pendingConnections -= 1 } }
        let connection: any WorkspaceSession
        if let savedEntry { connection = savedEntry.connection; sessions[savedEntry.id]?.busy = true }
        else {
            guard sessions.count + pendingConnections < policy.maximumSessions else { throw MCPFailure("Connection capacity reached.", code: .capacity) }
            pendingConnections += 1
            reservedConnection = true
            if metadataOnly, policy.tuning.maximumIdleConnections > 0, let reused = try await acquireMetadataConnection(profile: profile, database: database, mode: mode) {
                connection = reused
            } else {
                // Evict idle connections before opening another socket; reserve capacity before awaiting close.
                while sessions.count + pendingConnections + idleConnections.count > policy.maximumSessions, !idleConnections.isEmpty {
                    let retired = idleConnections.removeFirst(); await retired.connection.close()
                }
                connection = try await connect(profile, database: database, mode: mode)
            }
        }
        do {
            // Revalidate after potentially slow connection establishment.
            policy = try store.load()
            try policy.authorize(tool: tool, profile: profile, database: database)
            guard !stopped, policy.effectiveMode(profile, database: accessTarget) == mode else {
                throw MCPFailure("MCP permissions changed while connecting. Open a new session.", code: .accessDenied)
            }
            if tool == "open_table" {
                let name = try args.requiredString("table")
                guard policy.permitsObject(name, profile: profile),
                      let object = try await connection.fetchObjects(in: database ?? "").first(where: { policy.permitsObject($0, profile: profile, schema: args.string("schema")) && ($0.name == name || (args.string("schema") != nil && $0.nameWithinSchema == name)) }) else {
                    throw MCPFailure("Object is missing or outside the authorized scope.")
                }
                var request = args; request["table"] = .string(object.name); request["object_kind"] = .string(object.kind.rawValue)
                let result = try await MCPDesktopBridge.send(tool: tool, profile: profile, database: database, args: request, directory: store.url.deletingLastPathComponent())
                if savedEntry == nil { await connection.close() }
                return result
            }
            if tool == "open_session" {
                guard savedEntry == nil, sessions.count < policy.maximumSessions else { throw MCPFailure("Session limit reached or session already specified.", code: .capacity) }
                let sessionID = UUID().uuidString
                sessions[sessionID] = Session(id: sessionID, profile: profile, database: database, connection: connection, mode: mode)
                return .object(["session_id": .string(sessionID), "idle_timeout_seconds": .int(policy.sessionIdleSeconds)])
            }
            var result: Value
            if tool == "begin_transaction" || tool == "commit_transaction" {
                guard var entry = savedEntry else { throw MCPFailure("A session_id is required.") }
                let beginning = tool == "begin_transaction"
                guard beginning != entry.transaction else { throw MCPFailure("Invalid transaction state.") }
                try await transaction(beginning ? .begin : .commit, entry: entry)
                guard !stopped, sessions[entry.id] != nil else { throw MCPFailure("Session closed during transaction operation.") }
                entry.transaction = beginning; entry.busy = false; entry.lastUsed = Date(); sessions[entry.id] = entry
                result = .object(["status": .string(beginning ? "in_transaction" : "committed")])
            } else {
                result = try await execute(tool, args: args, profile: profile, database: database,
                                           connection: connection, policy: policy, inTransaction: savedEntry?.transaction ?? false)
            }
            if tool == "execute_and_show" {
                let data = try JSONEncoder().encode(result)
                do {
                    _ = try await MCPDesktopBridge.send(tool: tool, profile: profile, database: database, args: ["result_json": .string(String(decoding: data, as: UTF8.self))], directory: store.url.deletingLastPathComponent())
                } catch {
                    var payload = result.objectValue ?? [:]
                    payload["display_status"] = "failed"
                    payload["display_error"] = .string("Query completed but desktop display failed. Do not re-execute to retry display.")
                    result = .object(payload)
                }
            }
            if metadataOnly {
                // Do not publish metadata fetched across a concurrent edit or permission change.
                let current = try store.load()
                try current.authorize(tool: tool, profile: profile, database: database)
                guard current == policy else { throw MCPFailure("Permissions changed while reading metadata. Request it again.", code: .accessDenied) }
                guard try await repository.fetch(id: profile.id) == profile else {
                    throw MCPFailure("Connection changed while reading metadata.", code: .connectionNotFound)
                }
                try cacheMetadata(result, key: cacheKey, profile: profile, policy: policy, generation: cacheGeneration)
            }
            if let id { sessions[id]?.busy = false; sessions[id]?.lastUsed = Date() }
            else if metadataOnly { await releaseMetadataConnection(connection, profile: profile, database: database, mode: mode, policy: policy) }
            else { await connection.close() }
            return result
        } catch {
            // Failed/cancelled writes are never retried; discard a possibly poisoned session.
            if let id { sessions.removeValue(forKey: id) }
            await connection.close()
            throw error
        }
    }

    func connect(_ profile: ConnectionProfile, database: String?, mode: MCPExecutionMode) async throws -> any WorkspaceSession {
        let secret = profile.storesCredential ? try await credentials.password(for: profile.id) : nil
        if profile.storesCredential && secret == nil { throw MCPFailure("Saved credential is unavailable. Restore it in the QueryCraft connection editor.", code: .credentialUnavailable) }
        let configuration = DatabaseConnectionConfiguration(databaseType: profile.databaseType, databaseProduct: profile.databaseProduct,
            host: profile.host, port: profile.port, authentication: profile.authentication(secret: secret), database: database, tlsMode: profile.tlsMode)
        let session = try await registry.makeSession(configuration: configuration)
        do {
            let seconds = max(1, (try? store.load().effectiveQueryTimeoutSeconds).flatMap { $0 == 0 ? nil : $0 } ?? 30)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await WorkspaceKafkaAuthentication.configure(session, configuration: configuration, mechanism: profile.kafkaSASLMechanism ?? .plain)
                        try await session.connect()

                    } onCancel: { Task { await session.close() } }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    throw MCPFailure("Database connection timed out.", code: .timeout)
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            return session
        } catch { await session.close(); throw error }
    }

    func transaction(_ operation: SQLStatementKind.TransactionOperation, entry: Session) async throws {
        guard [.mysql, .postgresql].contains(entry.profile.databaseType), entry.connection.resolvedCapabilities.supportsTransactions else {
            throw MCPFailure("This driver does not support MCP SQL transactions.", code: .unsupported)
        }
        let sql = operation == .begin ? (entry.mode == .readOnly ? "START TRANSACTION READ ONLY" : "BEGIN") : operation == .commit ? "COMMIT" : "ROLLBACK"
        let seconds = max(1, (try? store.load().effectiveQueryTimeoutSeconds).flatMap { $0 == 0 ? nil : $0 } ?? 30)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    _ = try await entry.connection.executeStatement(sql, kind: .transaction(operation), database: entry.database, onBatch: { _ in })
                } onCancel: { Task { await entry.connection.close() } }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPFailure("Transaction operation timed out; its outcome may be unconfirmed. Do not retry automatically.", code: .timeout)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    func expireSessions(policy: MCPPolicy) async {
        let expired = sessions.values.filter { !$0.busy && Date().timeIntervalSince($0.lastUsed) >= Double(policy.sessionIdleSeconds) }
        for entry in expired { sessions.removeValue(forKey: entry.id) }
        for entry in expired { await entry.connection.close() }
    }
    func shutdown() async {
        stopped = true
        maintenance?.cancel(); maintenance = nil
        metadataCache.removeAll(); metadataGeneration &+= 1
        let idle = idleConnections; idleConnections.removeAll()
        for entry in idle { await entry.connection.close() }
        let entries = Array(sessions.values); sessions.removeAll()
        for entry in entries { await entry.connection.close() }
    }
}
