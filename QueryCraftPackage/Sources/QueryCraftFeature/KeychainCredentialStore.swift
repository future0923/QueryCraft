import Foundation
import Security

actor KeychainCredentialStore: CredentialStore {
    private let service = "io.github.future0923.QueryCraft.connection-profile"
    private let helper: WorkspaceCredentialHelperClient? =
        Bundle.main.object(forInfoDictionaryKey: "QCCredentialHelperRequired") as? Bool == true
            ? WorkspaceCredentialHelperClient() : nil

    func password(for profileID: UUID) async throws -> String? {
        if let helper {
            return try await helper.send(.init(operation: "get", account: profileID))
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

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
            _ = try await helper.send(.init(operation: "save", account: profileID, password: password))
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
            _ = try await helper.send(.init(operation: "delete", account: profileID))
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
