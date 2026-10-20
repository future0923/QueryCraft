import Foundation

/// MCP has its own immutable helper installation because desktop v1 deliberately
/// authenticates only desktop hosts. Never overwrite that existing helper.
actor MCPCredentialStore: CredentialStore {
    private let helper: WorkspaceCredentialHelperClient?
    private let fallback: KeychainCredentialStore
    private let shared: SharedKeychainCredentialStore?
    private let allowsInteraction: Bool
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory, allowsInteraction: Bool = false) {
        self.allowsInteraction = allowsInteraction
        fallback = KeychainCredentialStore(directory: directory, allowsInteraction: allowsInteraction)
        shared = Bundle.main.object(forInfoDictionaryKey: "QCSharedCredentialHelperRequired") as? Bool == true
            ? SharedKeychainCredentialStore(directory: directory) : nil
        if Bundle.main.object(forInfoDictionaryKey: "QCCredentialHelperRequired") as? Bool == true,
           Bundle.main.bundleIdentifier?.hasPrefix("io.github.future0923.QueryCraft.MCP") == true {
            helper = WorkspaceCredentialHelperClient(installationRoot: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/QueryCraftCredentials/mcp-v1"))
        } else { helper = nil }
    }
    func password(for profileID: UUID) async throws -> String? {
        if let shared { return try await shared.password(for: profileID) }
        if let helper { return try await helper.send(.init(operation: "get", account: profileID, allowsInteraction: allowsInteraction)) }
        return try await fallback.password(for: profileID)
    }
    func save(password: String, for profileID: UUID) async throws {
        if let shared { try await shared.save(password: password, for: profileID); return }
        if let helper { _ = try await helper.send(.init(operation: "save", account: profileID, password: password, allowsInteraction: allowsInteraction)) }
        else { try await fallback.save(password: password, for: profileID) }
    }
    func delete(for profileID: UUID) async throws {
        if let shared { try await shared.delete(for: profileID); return }
        if let helper { _ = try await helper.send(.init(operation: "delete", account: profileID, allowsInteraction: allowsInteraction)) }
        else { try await fallback.delete(for: profileID) }
    }
}
