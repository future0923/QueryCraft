import Foundation

extension MCPRuntime {
    struct MetadataCacheEntry: Sendable {
        let profile: ConnectionProfile
        let policy: MCPPolicy
        let value: MCPJSONValue
        let stored: Date
        let bytes: Int
    }
    struct IdleConnection: Sendable {
        let profile: ConnectionProfile
        let database: String?
        let mode: MCPExecutionMode
        let connection: any WorkspaceSession
        let returned: Date
    }
    func metadataKey(tool: String, args: [String: MCPJSONValue], profile: ConnectionProfile, database: String?, policy: MCPPolicy) throws -> String? {
        // Redis objects are live keys, not schema. Never cache key listings/details.
        guard profile.databaseType != .redis, MCPToolCatalog.metadataTools.contains(tool), policy.tuning.metadataCacheSeconds > 0 else { return nil }
        var canonical = args; canonical.removeValue(forKey: "refresh")
        canonical["database"] = database.map(MCPJSONValue.string)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return profile.id.uuidString + ":" + tool + ":" + String(decoding: try encoder.encode(canonical), as: UTF8.self)
    }
    func cachedMetadata(key: String?, profile: ConnectionProfile, policy: MCPPolicy, refresh: Bool, now: Date = Date()) -> MCPJSONValue? {
        guard let key else { return nil }
        guard !refresh, let entry = metadataCache[key], entry.profile == profile, entry.policy == policy,
              now.timeIntervalSince(entry.stored) < Double(policy.tuning.metadataCacheSeconds) else {
            metadataCache.removeValue(forKey: key); return nil
        }
        return entry.value
    }
    func cacheMetadata(_ value: MCPJSONValue, key: String?, profile: ConnectionProfile, policy: MCPPolicy, generation: UInt64) throws {
        guard let key, !stopped, generation == metadataGeneration,
              policy == (try store.load()) else { return }
        let bytes = try JSONEncoder().encode(value).count
        guard bytes <= min(262_144, policy.maximumResultBytes) else { return }
        metadataCache[key] = .init(profile: profile, policy: policy, value: value, stored: Date(), bytes: bytes)
        while metadataCache.count > 64 || metadataCache.values.reduce(0, { $0 + $1.bytes }) > 2_097_152 {
            guard let oldest = metadataCache.min(by: { $0.value.stored < $1.value.stored })?.key else { break }
            metadataCache.removeValue(forKey: oldest)
        }
    }
    func invalidateMetadata(for id: UUID) {
        metadataGeneration &+= 1
        metadataCache = metadataCache.filter { $0.value.profile.id != id }
    }
    func acquireMetadataConnection(profile: ConnectionProfile, database: String?, mode: MCPExecutionMode) async throws -> (any WorkspaceSession)? {
        guard let index = idleConnections.firstIndex(where: { $0.profile == profile && $0.database == database && $0.mode == mode }) else { return nil }
        let entry = idleConnections.remove(at: index) // Reserve before health-check suspension.
        guard Date().timeIntervalSince(entry.returned) < 60, await entry.connection.isConnected() else {
            await entry.connection.close(); return nil
        }
        return entry.connection
    }
    func releaseMetadataConnection(_ connection: any WorkspaceSession, profile: ConnectionProfile, database: String?, mode: MCPExecutionMode, policy: MCPPolicy) async {
        let current = try? store.load()
        guard !stopped, !Task.isCancelled, current == policy, policy.permits(profile), policy.tuning.maximumIdleConnections > 0,
              idleConnections.count < policy.tuning.maximumIdleConnections,
              activeConnectionCount + idleConnections.count <= policy.maximumSessions else {
            await connection.close(); return
        }
        idleConnections.append(.init(profile: profile, database: database, mode: mode, connection: connection, returned: Date()))
    }
    func retireIdleConnections(policy: MCPPolicy?, now: Date = Date()) async {
        var retired: [IdleConnection] = []
        idleConnections.removeAll { entry in
            let expired = policy == nil || policy?.permits(entry.profile) != true
                || policy?.effectiveMode(entry.profile, database: entry.database) != entry.mode
                || now.timeIntervalSince(entry.returned) >= 60
            if expired { retired.append(entry) }
            return expired
        }
        let allowedIdle = min(policy?.tuning.maximumIdleConnections ?? 0,
                              max(0, (policy?.maximumSessions ?? 0) - activeConnectionCount))
        while idleConnections.count > allowedIdle { retired.append(idleConnections.removeFirst()) }
        for entry in retired { await entry.connection.close() }
    }
    func discardIdleConnection(for id: UUID) async {
        let retired = idleConnections.filter { $0.profile.id == id }
        idleConnections.removeAll { $0.profile.id == id }
        for entry in retired { await entry.connection.close() }
    }
}
