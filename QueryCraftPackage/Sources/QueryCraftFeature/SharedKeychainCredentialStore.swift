import CryptoKit
import Foundation
import Security

/// No credentials are stored in preferences, profiles, process arguments or files.
/// The helper alone owns one Keychain vault per data directory, with a single
/// system access grant for every connection, shared by the desktop and MCP.
protocol CredentialImporting: CredentialStore {
    func importIfAbsent(password: String, for profileID: UUID) async throws
}

actor SharedKeychainCredentialStore: CredentialImporting {
    struct Record: Codable, Sendable {
        let password: String?
    }
    private let helper: WorkspaceCredentialHelperClient
    private let allowsInteraction: Bool
    private let vault: String
    static func vaultIdentifier(in directory: URL) -> String {
        SHA256.hash(data: Data(directory.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory,
         helper: WorkspaceCredentialHelperClient? = nil, allowsInteraction: Bool = false) {
        self.helper = helper ?? .shared(installationRoot: directory.appending(path: "Credentials/shared-v2"))
        self.allowsInteraction = allowsInteraction
        vault = Self.vaultIdentifier(in: directory)
    }

    func record(for profileID: UUID) async throws -> Record? {
        guard let value = try await helper.send(.init(operation: "get", account: profileID, allowsInteraction: allowsInteraction, vault: vault)) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: Data(value.utf8)) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
        }
        return record
    }
    func password(for profileID: UUID) async throws -> String? { try await record(for: profileID)?.password }
    func save(password: String, for profileID: UUID) async throws { try await write(.init(password: password), for: profileID) }
    func importIfAbsent(password: String, for profileID: UUID) async throws {
        // Insert-only migration cannot overwrite a concurrent desktop/MCP edit or deletion marker.
        try await write(.init(password: password), for: profileID, operation: "import")
    }
    func delete(for profileID: UUID) async throws {
        _ = try await helper.send(.init(operation: "clear", account: profileID, allowsInteraction: allowsInteraction, vault: vault))
    }
    private func write(_ record: Record, for profileID: UUID, operation: String = "save") async throws {
        let value = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        _ = try await helper.send(.init(operation: operation, account: profileID, password: value, allowsInteraction: allowsInteraction, vault: vault))
    }
}
