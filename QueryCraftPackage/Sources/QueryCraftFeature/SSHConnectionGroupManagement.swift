import Foundation

/// Kept only in memory while the shared catalog commits a group deletion.
struct SSHGroupDeletionBackup: Sendable {
    let profiles: [SSHConnection]
    let secrets: [UUID: String]
    let policy: MCPPolicy
}

extension SSHConnectionService {
    func removeGroup(_ expected: [SSHConnection]) async throws -> SSHGroupDeletionBackup {
        let snapshot = try snapshot()
        guard expected.allSatisfy(snapshot.profiles.contains) else { throw MCPFailure("Connections changed. Review the group again.") }
        let ids = Set(expected.map(\.id))
        try SSHConnectionStore.validateRoutes(snapshot.profiles.filter { !ids.contains($0.id) })
        // Dependents precede their jump hosts when removing; restoration reverses that order.
        let ordered = try expected.sorted {
            try SSHConnectionStore.route(to: $0, in: snapshot.profiles).count > SSHConnectionStore.route(to: $1, in: snapshot.profiles).count
        }
        var secrets: [UUID: String] = [:]
        for profile in ordered where profile.storesCredential {
            guard let secret = try await terminalCredentials.password(for: profile.id) else {
                throw MCPFailure("A saved credential is unavailable. The group was not deleted.", code: .credentialUnavailable)
            }
            secrets[profile.id] = secret
        }
        var removed: [SSHConnection] = []
        do {
            for profile in ordered { try await remove(profile); removed.append(profile) }
        } catch {
            let failure = error
            try await restoreGroup(.init(profiles: removed, secrets: secrets, policy: snapshot.policy))
            throw failure
        }
        return .init(profiles: removed, secrets: secrets, policy: snapshot.policy)
    }

    func restoreGroup(_ backup: SSHGroupDeletionBackup) async throws {
        for profile in backup.profiles.reversed() {
            let grant = SSHAccountAccess(id: profile.id, policy: backup.policy)
            try await save(profile, original: nil, secret: backup.secrets[profile.id], access: grant.access,
                fileRead: grant.fileRead, fileTransfer: grant.fileTransfer, fileManagement: grant.fileManagement)
        }
    }
}
