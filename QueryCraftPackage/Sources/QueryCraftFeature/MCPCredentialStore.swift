import Foundation

/// MCP has its own immutable helper installation because desktop v1 deliberately
/// authenticates only desktop hosts. Never overwrite that existing helper.
actor MCPCredentialStore: CredentialStore {
    private let helper: WorkspaceCredentialHelperClient?
    private let fallback = KeychainCredentialStore()
    private let allowsInteraction: Bool
    init(allowsInteraction: Bool = false) {
        self.allowsInteraction = allowsInteraction
        if Bundle.main.object(forInfoDictionaryKey: "QCCredentialHelperRequired") as? Bool == true,
           Bundle.main.bundleIdentifier?.hasPrefix("io.github.future0923.QueryCraft.MCP") == true {
            helper = WorkspaceCredentialHelperClient(installationRoot: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/QueryCraftCredentials/mcp-v1"))
        } else { helper = nil }
    }
    func password(for profileID: UUID) async throws -> String? {
        if let helper { return try await helper.send(.init(operation: "get", account: profileID, allowsInteraction: allowsInteraction)) }
        return try await fallback.password(for: profileID)
    }
    func save(password: String, for profileID: UUID) async throws {
        if let helper { _ = try await helper.send(.init(operation: "save", account: profileID, password: password, allowsInteraction: allowsInteraction)) }
        else { try await fallback.save(password: password, for: profileID) }
    }
    func delete(for profileID: UUID) async throws {
        if let helper { _ = try await helper.send(.init(operation: "delete", account: profileID, allowsInteraction: allowsInteraction)) }
        else { try await fallback.delete(for: profileID) }
    }
}
