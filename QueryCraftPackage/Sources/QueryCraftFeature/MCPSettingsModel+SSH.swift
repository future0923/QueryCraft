import Foundation

extension MCPSettingsModel {
    var filteredSSHProfiles: [SSHConnection] {
        sshProfiles.filter { search.isEmpty || "SSH \($0.name) \($0.host) \($0.username) \($0.id)".localizedCaseInsensitiveContains(search) }
    }

    func visibleSSHProfiles(in group: MCPPermissionGroup) -> [SSHConnection] {
        guard !search.isEmpty, !group.name.localizedCaseInsensitiveContains(search) else { return group.sshProfiles }
        let ids = Set(filteredSSHProfiles.map(\.id))
        return group.sshProfiles.filter { ids.contains($0.id) }
    }

    func updateSSHAccess(for id: UUID, _ update: (inout SSHAccountAccess) -> Void) {
        guard sshProfiles.contains(where: { $0.id == id }) else { return }
        var access = SSHAccountAccess(id: id, policy: policy)
        update(&access)
        access.apply(id: id, to: &policy)
    }

    /// Rechecking refreshes untouched grants, preserving local edits for conflict checking at save.
    func rebaseSSHProfiles(_ snapshot: MCPSettingsSnapshot) {
        var original = MCPPolicy(); original.ssh = originalSSHPolicy
        let ids = Set(sshProfiles.map(\.id) + snapshot.sshProfiles.map(\.id))
        for id in ids where SSHAccountAccess(id: id, policy: policy) == SSHAccountAccess(id: id, policy: original) {
            let latest = SSHAccountAccess(id: id, policy: snapshot.policy)
            latest.apply(id: id, to: &policy)
            latest.apply(id: id, to: &original)
        }
        originalSSHPolicy = original.ssh
        sshProfiles = snapshot.sshProfiles
    }

    func persistSettingsPolicy() throws {
        policy.ssh = try MCPPolicyStore(directory: directory).saveSettings(
            policy, originalSSH: originalSSHPolicy, sshProfiles: sshProfiles).ssh
        originalSSHPolicy = policy.ssh
        NotificationCenter.default.post(name: SSHConnectionService.settingsChanged, object: directory.path)
    }
}
