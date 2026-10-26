import CryptoKit
import Foundation
import Darwin

enum SSHAccess: String, CaseIterable, Sendable {
    case denied, connect, execute
    var title: String {
        switch self {
        case .denied: AppCopy.current.text("禁止 MCP", "No MCP access")
        case .connect: AppCopy.current.text("允许连接", "Allow connections")
        case .execute: AppCopy.current.text("允许执行命令", "Allow commands")
        }
    }
    func apply(id: UUID, to policy: inout MCPPolicy) {
        var ssh = policy.ssh ?? MCPSSHPolicy()
        ssh.connectionIDs.remove(id); ssh.executionConnectionIDs.remove(id)
        if self != .denied { ssh.connectionIDs.insert(id) }
        if self == .execute { ssh.executionConnectionIDs.insert(id) }
        if self == .denied { ssh.fileReadConnectionIDs.remove(id); ssh.fileTransferConnectionIDs.remove(id); ssh.fileManagementConnectionIDs.remove(id) }
        policy.ssh = ssh
    }
    static func current(id: UUID, policy: MCPPolicy) -> Self {
        guard policy.ssh?.connectionIDs.contains(id) == true else { return .denied }
        return policy.ssh?.executionConnectionIDs.contains(id) == true ? .execute : .connect
    }
}

/// Shared local account operations. Passwords never enter the profile file or UI snapshots.
actor SSHConnectionService {
    let directory: URL
    private let credentials: any CredentialStore
    private let transport: (any SSHTransport)?
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory,
         credentials: (any CredentialStore)? = nil, transport: (any SSHTransport)? = nil) {
        self.directory = directory
        self.credentials = credentials ?? KeychainCredentialStore(directory: directory, allowsInteraction: true)
        self.transport = transport
    }
    var terminalCredentials: any CredentialStore { credentials }
    func connectionGroups() async throws -> [ConnectionGroup] {
        try await SQLiteConnectionProfileRepository(databaseURL: directory.appending(path: "QueryCraft.sqlite"))
            .fetchManagementSnapshot().groups
    }
    func snapshot() throws -> (profiles: [SSHConnection], policy: MCPPolicy) {
        (try SSHConnectionStore(directory: directory).load(), try MCPPolicyStore(directory: directory).load())
    }
    func move(_ profile: SSHConnection, to groupID: UUID?, beforeID: UUID?) throws {
        let lock = try accountLock(); defer { withExtendedLifetime(lock) {} }
        try SSHConnectionStore(directory: directory).move(profile, to: groupID, beforeID: beforeID)
        NotificationCenter.default.post(name: Self.settingsChanged, object: directory.path)
    }
    func save(_ profile: SSHConnection, original: SSHConnection?, secret: String?, access: SSHAccess,
              fileRead: Bool? = nil, fileTransfer: Bool? = nil, fileManagement: Bool? = nil, expectingAccess: SSHAccountAccess? = nil) async throws {
        try profile.validate()
        guard secret == nil || profile.storesCredential,
              secret.map({ !$0.contains("\0") && $0.utf8.count <= 65_536 }) ?? true else { throw MCPFailure("Invalid SSH credential.") }
        let lock = try accountLock(); defer { withExtendedLifetime(lock) {} }
        let store = SSHConnectionStore(directory: directory)
        guard try store.load().first(where: { $0.id == profile.id }) == original else {
            throw MCPFailure(AppCopy.current.text("连接已变化，请重新加载。", "The connection changed. Reload it."))
        }
        try SSHConnectionStore.validateRoutes(try store.load().filter { $0.id != profile.id } + [profile])
        let retainsSecret = original?.storesCredential == true && original?.authenticationMethod == profile.authenticationMethod && original?.privateKeyPath == profile.privateKeyPath
        if profile.storesCredential && secret == nil && !retainsSecret {
            throw MCPFailure(AppCopy.current.text("请输入密码或私钥口令。", "Enter the password or key passphrase."), code: .credentialUnavailable)
        }
        // Renaming or revoking access must work even when the Keychain is locked.
        // Read the old value only when credential compensation may be required.
        let changesCredential = secret != nil || original?.storesCredential != profile.storesCredential
        let oldSecret = changesCredential && original?.storesCredential == true ? try await credentials.password(for: profile.id) : nil
        var changedSecret = false
        if let secret { try await credentials.save(password: secret, for: profile.id); changedSecret = true }
        else if !profile.storesCredential && oldSecret != nil { try await credentials.delete(for: profile.id); changedSecret = true }
        var saved = false
        do {
            try Task.checkCancellation()
            if let original { try store.replace(profile, expecting: original) } else { try store.insert(profile) }
            saved = true
            try MCPPolicyStore(directory: directory).update { policy in
                if let expectingAccess, SSHAccountAccess(id: profile.id, policy: policy) != expectingAccess {
                    throw MCPFailure(AppCopy.current.text("授权已在其他页面修改，请重新打开后保存。", "Access changed in another view. Reopen before saving."))
                }
                access.apply(id: profile.id, to: &policy)
                if access != .denied {
                    if let fileManagement {
                        if fileManagement { policy.ssh?.fileManagementConnectionIDs.insert(profile.id) }
                        else { policy.ssh?.fileManagementConnectionIDs.remove(profile.id) }
                    }
                    if let fileRead {
                        if fileRead { policy.ssh?.fileReadConnectionIDs.insert(profile.id) }
                        else { policy.ssh?.fileReadConnectionIDs.remove(profile.id) }
                    }
                    if let fileTransfer {
                        if fileTransfer { policy.ssh?.fileTransferConnectionIDs.insert(profile.id) }
                        else { policy.ssh?.fileTransferConnectionIDs.remove(profile.id) }
                    }
                }
            }
            NotificationCenter.default.post(name: Self.settingsChanged, object: directory.path)
        } catch {
            if saved {
                if let original { try? store.replace(original, expecting: profile) } else { try? store.remove(id: profile.id) }
            }
            if changedSecret {
                if let oldSecret { try? await credentials.save(password: oldSecret, for: profile.id) }
                else { try? await credentials.delete(for: profile.id) }
            }
            throw error
        }
    }
    func remove(_ profile: SSHConnection) async throws {
        let lock = try accountLock(); defer { withExtendedLifetime(lock) {} }
        let store = SSHConnectionStore(directory: directory)
        guard try store.load().contains(profile) else { throw MCPFailure("SSH connection changed. Reload it.") }
        guard try !store.load().contains(where: { $0.jumpConnectionID == profile.id }) else { throw MCPFailure("This server is used as a jump host. Update its dependent connections first.") }
        // Revoke before touching credentials so new MCP calls cannot use a partially removed account.
        try MCPPolicyStore(directory: directory).update { SSHAccess.denied.apply(id: profile.id, to: &$0) }
        if profile.storesCredential { try await credentials.delete(for: profile.id) }
        try store.remove(id: profile.id)
        NotificationCenter.default.post(name: Self.settingsChanged, object: directory.path)
    }
    func test(_ profile: SSHConnection, secret: String?) async throws {
        let plugin: any SSHTransport
        if let transport { plugin = transport }
        else { plugin = try SSHPlugin(bundleURL: SSHPlugin.bundleURL(in: directory)) }
        let jumps = try SSHConnectionStore.route(to: profile, in: SSHConnectionStore(directory: directory).load())
        guard jumps.isEmpty && profile.authenticationMethod != .agent || plugin.supportsRoutes else { throw MCPFailure("Upgrade SSH to 0.6.0 for jump hosts and agent authentication.", code: .unsupported) }
        let request = try await SSHRouteRequest.make(profile: profile, jumps: jumps, credentials: credentials, secretOverride: secret,
            timeoutMilliseconds: 15_000, maximumOutputBytes: 1024)
        try Task.checkCancellation()
        guard try SSHConnectionStore.route(to: profile, in: SSHConnectionStore(directory: directory).load()) == jumps else { throw MCPFailure("SSH jump configuration changed. Test again.") }
        let result = try await plugin.execute(request)
        try result.validate()
    }
    /// Revalidate the reviewed script and the live terminal's pinned route before
    /// queuing any input. This does not read credentials or start another SSH job.
    func validateTerminalScript(_ script: ShellScript, endpoints: [SSHConnection]) throws {
        try Task.checkCancellation()
        guard let profile = endpoints.last,
              try ShellScriptStore(directory: directory).load().first(where: { $0.id == script.id }) == script else {
            throw MCPFailure(AppCopy.current.text("脚本已变化或删除，请重新查看后操作。", "The script changed or was removed. Review it again."), code: .sessionBusy)
        }
        let profiles = try SSHConnectionStore(directory: directory).load()
        guard profiles.contains(profile),
              try SSHConnectionStore.route(to: profile, in: profiles) + [profile] == endpoints else {
            throw MCPFailure(AppCopy.current.text("连接配置已变化，请重新连接终端。", "The connection changed. Reconnect the terminal."), code: .sessionBusy)
        }
    }

    func fingerprint(host: String, port: Int, jumpConnectionID: UUID? = nil) async throws -> String {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace }), !host.contains("\0"),
              (1...65535).contains(port) else { throw MCPFailure("Invalid SSH address or port.") }
        let plugin = transport ?? (try? SSHPlugin(bundleURL: SSHPlugin.bundleURL(in: directory)))
        if let plugin, plugin.supportsRoutes {
            let probe = SSHConnection(id: UUID(), name: "Host-key probe", host: host, port: port, username: "probe",
                hostFingerprint: "SHA256:" + String(repeating: "A", count: 43), privateKeyPath: nil, storesCredential: true, jumpConnectionID: jumpConnectionID)
            let jumps = try SSHConnectionStore.route(to: probe, in: SSHConnectionStore(directory: directory).load())
            let request = try await SSHRouteRequest.make(profile: probe, jumps: jumps, credentials: credentials,
                timeoutMilliseconds: 15_000, maximumOutputBytes: 1024, scanHostKey: true)
            guard try SSHConnectionStore.route(to: probe, in: SSHConnectionStore(directory: directory).load()) == jumps else { throw MCPFailure("Jump-host configuration changed.") }
            let result = try await plugin.execute(request); try result.validate()
            let fingerprint = String(decoding: result.stdout, as: UTF8.self)
            guard fingerprint.hasPrefix("SHA256:"), fingerprint.count == 50 else { throw MCPFailure("Invalid host fingerprint result.") }
            return fingerprint
        }
        guard jumpConnectionID == nil else { throw MCPFailure("Upgrade SSH to 0.6.0 to read a fingerprint through a jump host.", code: .unsupported) }
        let output = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
            arguments: ["-T", "5", "-p", String(port), "-t", "ecdsa,ed25519,rsa", host], timeout: 10)
        for algorithm in ["ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-ed25519", "ssh-rsa"] {
            for line in output.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count >= 3, fields[1] == algorithm, let data = Data(base64Encoded: String(fields[2])) {
                    return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
                }
            }
        }
        throw MCPFailure(AppCopy.current.text("未读取到服务器指纹，请手动填写。", "No host fingerprint was received. Enter it manually."))
    }
    private func accountLock() throws -> MCPComponentLock {
        try MCPComponentLock(directory: directory.appending(path: "SSHAccountOperations"))
    }
}
