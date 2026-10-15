import Foundation

struct MCPSettingsSnapshot: Sendable {
    let policy: MCPPolicy
    let connections: ConnectionManagementSnapshot
}

struct MCPSettingsRuntimeStatus: Sendable {
    let installedVersion: String?
    let availableVersion: String?
    let httpRunning: Bool
}

/// Policy file access and SQLite initialization belong off the UI actor.
actor MCPSettingsLoader {
    private let store: MCPPolicyStore
    private let repository: SQLiteConnectionProfileRepository

    init(directory: URL) {
        store = MCPPolicyStore(directory: directory)
        repository = SQLiteConnectionProfileRepository(databaseURL: directory.appending(path: "QueryCraft.sqlite"))
    }

    func load() async throws -> MCPSettingsSnapshot {
        let policy = try store.load()
        let connections = try await repository.fetchManagementSnapshot()
        return MCPSettingsSnapshot(policy: policy, connections: connections)
    }
}
