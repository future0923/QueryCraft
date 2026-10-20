import Foundation

enum MCPCredentialAuthorization {
    /// Read everything before writing anything. Missing/denied legacy credentials
    /// fail without partial migration or opening a sequence of system dialogs.
    static func authorize(profiles: [ConnectionProfile], policy: MCPPolicy,
                          source: any CredentialStore, destination: any CredentialImporting, legacy: (any CredentialStore)? = nil) async throws -> Int {
        var passwords: [(UUID, String)] = []
        for profile in profiles where policy.permits(profile) && profile.storesCredential
            && policy.connectionRule(profile).allowedDatabases?.isEmpty != true {
            try Task.checkCancellation()
            do {
                guard let password = try await source.password(for: profile.id) else {
                    throw MCPFailure("Saved credential is missing. Restore it in the connection editor.", code: .credentialUnavailable)
                }
                passwords.append((profile.id, password))
            } catch { throw MCPFailure.normalized(error) }
        }
        for (id, password) in passwords {
            try Task.checkCancellation()
            do { try await destination.importIfAbsent(password: password, for: id) }
            catch { throw MCPFailure.normalized(error) }
        }
        if let legacy {
            for (id, _) in passwords {
                try Task.checkCancellation()
                do {
                    guard try await destination.password(for: id) != nil else {
                        throw MCPFailure("Credential changed during migration. Retry authorization.", code: .credentialUnavailable)
                    }
                    try await legacy.delete(for: id)
                } catch { throw MCPFailure.normalized(error) }
            }
        }
        return passwords.count
    }
}
