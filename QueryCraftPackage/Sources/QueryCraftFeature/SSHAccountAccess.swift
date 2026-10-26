import Foundation

struct SSHAccountAccess: Equatable, Sendable {
    var access: SSHAccess
    var fileRead: Bool
    var fileManagement: Bool
    var fileTransfer: Bool
    init(id: UUID, policy: MCPPolicy) {
        fileManagement = policy.ssh?.fileManagementConnectionIDs.contains(id) == true
        access = SSHAccess.current(id: id, policy: policy)
        fileRead = policy.ssh?.fileReadConnectionIDs.contains(id) == true
        fileTransfer = policy.ssh?.fileTransferConnectionIDs.contains(id) == true
    }
    func apply(id: UUID, to policy: inout MCPPolicy) {
        access.apply(id: id, to: &policy)
        if access != .denied {
            if fileManagement { policy.ssh?.fileManagementConnectionIDs.insert(id) } else { policy.ssh?.fileManagementConnectionIDs.remove(id) }
            if fileRead { policy.ssh?.fileReadConnectionIDs.insert(id) } else { policy.ssh?.fileReadConnectionIDs.remove(id) }
            if fileTransfer { policy.ssh?.fileTransferConnectionIDs.insert(id) } else { policy.ssh?.fileTransferConnectionIDs.remove(id) }
        }
    }
}
extension SSHConnectionService {
    static let settingsChanged = Notification.Name("QueryCraftSSHSettingsChanged")
    func updateAccess(_ profile: SSHConnection, expecting original: SSHAccountAccess, value: SSHAccountAccess) throws {
        let lock = try MCPComponentLock(directory: directory.appending(path: "SSHAccountOperations"))
        defer { withExtendedLifetime(lock) {} }
        guard try SSHConnectionStore(directory: directory).load().contains(profile) else { throw MCPFailure("SSH connection changed. Reload it.") }
        try MCPPolicyStore(directory: directory).update { policy in
            guard SSHAccountAccess(id: profile.id, policy: policy) == original else {
                throw MCPFailure(AppCopy.current.text("授权已在其他页面修改，请重新加载后再保存。", "Access changed in another view. Reload before saving."))
            }
            value.apply(id: profile.id, to: &policy)
        }
        NotificationCenter.default.post(name: Self.settingsChanged, object: directory.path)
    }
}
