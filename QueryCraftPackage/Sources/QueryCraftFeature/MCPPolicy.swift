import Foundation
import Darwin


enum MCPExecutionMode: String, Codable, CaseIterable, Sendable {
    case readOnly = "read_only", dataWrite = "safe_write", fullAccess = "high_risk_write"
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        switch self {
        case .readOnly: AppCopy.current.text("只读", "Read only")
        case .dataWrite: AppCopy.current.text("数据读写", "Data read/write")
        case .fullAccess: AppCopy.current.text("完整访问", "Full access")
        }
    }
}

enum MCPDatabaseAccess: String, Codable, CaseIterable, Sendable {
    case all, selected, none
}

struct MCPConnectionPolicy: Codable, Equatable, Sendable {
    var databases: Set<String>? = nil
    var mode: MCPExecutionMode? = nil
    var databaseModes: [String: MCPExecutionMode] = [:]
    // Optional for compatibility with policies written before explicit scope modes.
    var databaseAccess: MCPDatabaseAccess? = nil
    var scope: MCPDatabaseAccess { databaseAccess ?? (databases == nil ? .all : .selected) }
    var allowedDatabases: Set<String>? {
        switch scope { case .all: nil; case .selected: databases ?? []; case .none: [] }
    }
}

struct MCPHTTPSettings: Codable, Equatable, Sendable {
    var host = "127.0.0.1"
    var port = 5226
    var path = "/mcp"
    var allowsRemote = false
    var allowedHosts: [String] = ["127.0.0.1", "localhost", "[::1]"]
    var allowedOrigins: [String] = []
    var token = UUID().uuidString + UUID().uuidString
    var endpoint: String { "http://\(host.contains(":") ? "[\(host)]" : host):\(port)\(path)" }
    func validate() throws {
        guard (1024...65535).contains(port), path.hasPrefix("/"), !path.contains("?"),
              !path.contains("#"), !path.contains(" "), token.count >= 32 else {
            throw MCPFailure("Invalid MCP HTTP port, path or token (minimum 32 characters).")
        }
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(host)
        guard loopback || (allowsRemote && !allowedHosts.isEmpty && !allowedOrigins.isEmpty) else {
            throw MCPFailure("Remote HTTP requires explicit access, Host and Origin allowlists.")
        }
        guard !allowedHosts.contains("*"), !allowedOrigins.contains("*") else {
            throw MCPFailure("Wildcard HTTP Host/Origin authorization is not supported.")
        }
    }
}

enum MCPToolDiscovery: String, Codable, CaseIterable, Sendable {
    case flat, lazy, both
}
struct MCPOptimizationSettings: Codable, Equatable, Sendable {
    var discovery: MCPToolDiscovery = .both
    var metadataCacheSeconds = 30
    var maximumIdleConnections = 4
    var recordsHistory = true
}

struct MCPPolicy: Codable, Equatable, Sendable {
    var ssh: MCPSSHPolicy? = nil
    var optimizations: MCPOptimizationSettings? = nil
    var tuning: MCPOptimizationSettings { optimizations ?? .init() }
    var version = 1
    var enabled = false
    var allConnections = false
    var connectionIDs: Set<UUID> = []
    var groupIDs: Set<UUID> = []
    var mode: MCPExecutionMode = .readOnly
    var groupModes: [String: MCPExecutionMode] = [:]
    var connections: [String: MCPConnectionPolicy] = [:]
    var disabledTools: Set<String> = []
    var queryTimeoutSeconds: Int? = nil
    // QueryCraft has a global query timeout, not a per-connection timeout.
    // Persist a snapshot so the independent helper can inherit it without the desktop running.
    var inheritedQueryTimeoutSeconds: Int? = nil
    var effectiveQueryTimeoutSeconds: Int { queryTimeoutSeconds ?? inheritedQueryTimeoutSeconds ?? 60 }
    var maximumRows = 1000
    var maximumResultBytes = 4 * 1024 * 1024
    var sessionIdleSeconds = 1800
    var maximumSessions = 32
    var http = MCPHTTPSettings()

    func permits(_ profile: ConnectionProfile) -> Bool {
        enabled && includesConnection(profile)
    }
    func includesConnection(_ profile: ConnectionProfile) -> Bool {
        (allConnections || connectionIDs.contains(profile.id)
            || profile.groupID.map { groupIDs.contains($0) } == true)
    }
    func connectionRule(_ profile: ConnectionProfile) -> MCPConnectionPolicy {
        connections[profile.id.uuidString] ?? MCPConnectionPolicy()
    }
    func permitsObject(_ name: String, profile: ConnectionProfile) -> Bool {
        guard [.kafka, .elasticsearch].contains(profile.databaseType), let allowed = connectionRule(profile).allowedDatabases else { return true }
        return allowed.contains(name)
    }
    func permitsObject(_ object: WorkspaceDatabaseObject, profile: ConnectionProfile, schema: String?) -> Bool {
        permitsObject(object.name, profile: profile)
            && (profile.databaseType != .postgresql || schema == nil || object.schemaName == schema)
    }
    func effectiveMode(_ profile: ConnectionProfile, database: String?) -> MCPExecutionMode {
        let rule = connectionRule(profile)
        let ceilings = [mode, profile.groupID.flatMap { groupModes[$0.uuidString] },
                        rule.mode, database.flatMap { rule.databaseModes[$0] }].compactMap { $0 }
        return ceilings.min(by: { $0.rank < $1.rank }) ?? mode
    }
    func authorize(tool: String, profile: ConnectionProfile? = nil, database: String? = nil) throws {
        guard version == 1, enabled else { throw MCPFailure("MCP is disabled. Enable it in QueryCraft Settings → MCP.", code: .accessDenied) }
        guard !disabledTools.contains(tool) else { throw MCPFailure("This tool is disabled by MCP settings.", code: .accessDenied) }
        if let profile {
            guard permits(profile) else { throw MCPFailure("Connection is not authorized for MCP.", code: .accessDenied) }
            guard connectionRule(profile).allowedDatabases?.isEmpty != true else {
                throw MCPFailure("Database access is denied for this connection.", code: .accessDenied)
            }
            if ![.kafka, .elasticsearch].contains(profile.databaseType), let allowed = connectionRule(profile).allowedDatabases {
                let selected = database ?? (profile.databaseType == .redis ? "0" : nil)
                if let selected {
                    guard allowed.contains(selected) else { throw MCPFailure("Database is outside the authorized MCP scope.", code: .accessDenied) }
                } else if tool != "list_databases" {
                    throw MCPFailure("Select an authorized database first.", code: .accessDenied)
                }
            }
        }
    }
    func validate() throws {
        guard version == 1, (0...86400).contains(effectiveQueryTimeoutSeconds), (1...10000).contains(maximumRows),
              (1024...16_777_216).contains(maximumResultBytes), (30...86400).contains(sessionIdleSeconds),
              (1...128).contains(maximumSessions) else { throw MCPFailure("Invalid MCP policy limits or version.") }
        guard (0...300).contains(tuning.metadataCacheSeconds), (0...8).contains(tuning.maximumIdleConnections) else {
            throw MCPFailure("Invalid MCP optimization limits.")
        }
        try http.validate()
    }
}

/// Re-read on each request so other processes immediately see revocations.
struct MCPPolicyStore: Sendable {
    let url: URL
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory) {
        url = directory.appending(path: "mcp-policy.json")
    }
    func load() throws -> MCPPolicy {
        guard FileManager.default.fileExists(atPath: url.path) else { return MCPPolicy() }
        do {
            let policy = try JSONDecoder().decode(MCPPolicy.self, from: Data(contentsOf: url))
            try policy.validate()
            return policy
        } catch { throw MCPFailure("MCP policy cannot be read. Repair and save it in QueryCraft settings.", code: .policyUnavailable) }
    }
    func save(_ policy: MCPPolicy) throws {
        try withLock { try write(policy) }
    }
    /// Serialize read/modify/write across desktop and independent MCP processes.
    func update(_ change: (inout MCPPolicy) throws -> Void) throws {
        try withLock {
            var policy = try load()
            try change(&policy)
            try write(policy)
        }
    }
    private func withLock(_ operation: () throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.appending(path: ".mcp-policy.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MCPFailure("Cannot lock MCP policy.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw MCPFailure("Cannot lock MCP policy.") }
        defer { flock(descriptor, LOCK_UN) }
        try operation()
    }
    func savePreservingSSH(_ policy: MCPPolicy) throws {
        try update { current in
            let ssh = current.ssh
            current = policy
            current.ssh = ssh
        }
    }
    private func write(_ policy: MCPPolicy) throws {
        try policy.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = url.deletingLastPathComponent().appending(path: ".mcp-policy-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw MCPFailure("Cannot create private MCP policy file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: encoder.encode(policy)); try handle.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw MCPFailure("Cannot atomically save MCP policy.") }
    }
}
