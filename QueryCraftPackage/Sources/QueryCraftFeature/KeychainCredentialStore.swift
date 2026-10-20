import Foundation
import Security

/// Legacy desktop helper v1 remains immutable and is used only for unmigrated items.
actor LegacyKeychainCredentialStore: CredentialStore {
    private let allowsInteraction: Bool
    init(allowsInteraction: Bool = true) { self.allowsInteraction = allowsInteraction }
    private let service = "io.github.future0923.QueryCraft.connection-profile"
    private let helper: WorkspaceCredentialHelperClient? =
        Bundle.main.object(forInfoDictionaryKey: "QCCredentialHelperRequired") as? Bool == true
            ? WorkspaceCredentialHelperClient() : nil

    func password(for profileID: UUID) async throws -> String? {
        if let helper {
            return try await helper.send(.init(operation: "get", account: profileID, allowsInteraction: allowsInteraction))
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        if !allowsInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError(status: errSecDecode)
        }
        return String(data: data, encoding: .utf8)
    }

    func save(password: String, for profileID: UUID) async throws {
        if let helper {
            _ = try await helper.send(.init(operation: "save", account: profileID, password: password, allowsInteraction: allowsInteraction))
            return
        }
        let account = profileID.uuidString
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let data = Data(password.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = baseQuery
            insertQuery[kSecValueData as String] = data
            insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(insertQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func delete(for profileID: UUID) async throws {
        if let helper {
            _ = try await helper.send(.init(operation: "delete", account: profileID, allowsInteraction: allowsInteraction))
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Both desktop and independent MCP use the same immutable, caller-checked helper.
/// An explicit deletion marker prevents old legacy passwords from resurfacing.
actor KeychainCredentialStore: CredentialStore {
    private let legacy: any CredentialStore
    private let shared: SharedKeychainCredentialStore?

    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory, allowsInteraction: Bool = true) {
        // Old per-item grants must never trigger a sequence of automatic dialogs.
        legacy = LegacyKeychainCredentialStore(allowsInteraction: false)
        shared = Bundle.main.object(forInfoDictionaryKey: "QCSharedCredentialHelperRequired") as? Bool == true
            ? SharedKeychainCredentialStore(directory: directory, allowsInteraction: allowsInteraction) : nil
    }

    func password(for profileID: UUID) async throws -> String? {
        if let record = try await shared?.record(for: profileID) { return record.password }
        return try await legacy.password(for: profileID)
    }

    func save(password: String, for profileID: UUID) async throws {
        if let shared {
            try await shared.save(password: password, for: profileID)
            // The vault is now authoritative. An inaccessible obsolete legacy copy
            // must not prevent the user from restoring a password in the editor.
            try? await legacy.delete(for: profileID)
        }
        else { try await legacy.save(password: password, for: profileID) }
    }

    func delete(for profileID: UUID) async throws {
        // Remove legacy data first; a failed deletion must not expose stale fallback data.
        try await legacy.delete(for: profileID)
        try await shared?.delete(for: profileID)
    }
}
