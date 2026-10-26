import Foundation

enum MCPCredentialAuthorization {
    struct Report: Sendable {
        let authorizedCount: Int
        let unavailableProfiles: [ConnectionProfile]
    }

    /// An inaccessible historical item must not block unrelated, readable grants.
    /// Snapshot every readable password before importing; never alter unavailable items.
    static func authorizeAvailable(profiles: [ConnectionProfile], policy: MCPPolicy,
                                   source: any CredentialStore, destination: any CredentialImporting,
                                   legacy: (any CredentialStore)? = nil) async throws -> Report {
        var readable: [ConnectionProfile] = []
        var unavailable: [ConnectionProfile] = []
        var passwords: [UUID: String] = [:]
        for profile in eligible(profiles, policy: policy) {
            try Task.checkCancellation()
            do {
                passwords[profile.id] = try await savedPassword(for: profile, source: source)
                readable.append(profile)
            } catch {
                let failure = MCPFailure.normalized(error)
                guard failure.code == .credentialDenied || failure.code == .credentialUnavailable else { throw failure }
                unavailable.append(profile)
            }
        }
        let count = try await authorize(profiles: readable, policy: policy,
            source: InMemoryCredentialStore(passwords: passwords), destination: destination, legacy: legacy)
        return Report(authorizedCount: count, unavailableProfiles: unavailable)
    }

    /// Read everything before writing anything. Missing/denied legacy credentials
    /// fail without partial migration or opening a sequence of system dialogs.
    static func authorize(profiles: [ConnectionProfile], policy: MCPPolicy,
                          source: any CredentialStore, destination: any CredentialImporting, legacy: (any CredentialStore)? = nil) async throws -> Int {
        let copy = AppCopy.current
        var passwords: [(ConnectionProfile, String)] = []
        for profile in eligible(profiles, policy: policy) {
            try Task.checkCancellation()
            passwords.append((profile, try await savedPassword(for: profile, source: source)))
        }
        for (profile, password) in passwords {
            try Task.checkCancellation()
            do { try await destination.importIfAbsent(password: password, for: profile.id) }
            catch {
                let failure = MCPFailure.normalized(error)
                guard failure.code != .cancelled && failure.code != .credentialCancelled else { throw failure }
                throw MCPFailure(copy.text(
                    "无法将连接“\(profile.name)”的密码写入共享钥匙串。请解锁登录钥匙串并允许 QueryCraft 凭据助手访问后重试。旧密码尚未清理。",
                    "Cannot import the password for “\(profile.name)” into the shared Keychain vault. Unlock the login Keychain and allow the QueryCraft credential helper, then retry. Legacy passwords have not been removed."), code: failure.code)
            }
        }
        if let legacy {
            for (profile, _) in passwords {
                try Task.checkCancellation()
                do {
                    guard try await destination.password(for: profile.id) != nil else {
                        throw MCPFailure("Credential changed during migration. Retry authorization.", code: .credentialUnavailable)
                    }
                } catch {
                    let failure = MCPFailure.normalized(error)
                    guard failure.code != .cancelled && failure.code != .credentialCancelled else { throw failure }
                    throw MCPFailure(copy.text(
                        "无法确认连接“\(profile.name)”的共享密码可用。旧副本尚未清理；请检查钥匙串访问权限后重试授权。",
                        "Cannot verify the shared password for “\(profile.name)”. Its legacy copy has not been removed. Check Keychain access and retry authorization."), code: failure.code)
                }
                do { try await legacy.delete(for: profile.id) }
                catch {
                    let failure = MCPFailure.normalized(error)
                    guard failure.code != .cancelled && failure.code != .credentialCancelled else { throw failure }
                    throw MCPFailure(copy.text(
                        "共享密码已保存，但无法清理连接“\(profile.name)”的旧钥匙串副本。请解锁登录钥匙串并检查旧凭据访问权限后重试授权。",
                        "The shared password is saved, but the legacy Keychain copy for “\(profile.name)” could not be removed. Unlock the login Keychain, check legacy credential access, and retry authorization."), code: failure.code)
                }
            }
        }
        return passwords.count
    }

    private static func eligible(_ profiles: [ConnectionProfile], policy: MCPPolicy) -> [ConnectionProfile] {
        profiles.filter { policy.permits($0) && $0.storesCredential
            && policy.connectionRule($0).allowedDatabases?.isEmpty != true }
    }

    private static func savedPassword(for profile: ConnectionProfile, source: any CredentialStore) async throws -> String {
        do {
            guard let password = try await source.password(for: profile.id) else {
                throw MCPFailure("Saved credential is missing. Restore it in the connection editor.", code: .credentialUnavailable)
            }
            return password
        } catch {
            let failure = MCPFailure.normalized(error)
            guard failure.code != .cancelled && failure.code != .credentialCancelled else { throw failure }
            throw MCPFailure(AppCopy.current.text(
                "无法读取连接“\(profile.name)”的已保存密码。请解锁登录钥匙串；若仍失败，请在连接编辑器重新输入并保存密码后重试授权。旧凭据不会逐条弹出授权。",
                "Cannot read the saved password for “\(profile.name)”. Unlock the login Keychain. If access still fails, re-enter and save the password in the connection editor, then retry authorization. Legacy items will not prompt individually."), code: failure.code)
        }
    }
}
