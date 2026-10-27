import Foundation
import Observation

@MainActor @Observable
final class SSHSettingsModel {
    var profiles: [SSHConnection] = []
    var policy = MCPPolicy()
    var loaded = false
    var busy = false
    var error: String?
    var status = ""
    var search = ""
    private var reloadPending = false
    let service: SSHConnectionService
    init(service: SSHConnectionService = SSHConnectionService()) { self.service = service }
    var filtered: [SSHConnection] {
        profiles.filter { search.isEmpty || "\($0.name) \($0.host) \($0.username)".localizedCaseInsensitiveContains(search) }
    }
    func load() async {
        guard !busy else { reloadPending = true; return }; busy = true
        defer {
            busy = false
            if reloadPending { reloadPending = false; Task { await self.load() } }
        }
        do {
            let snapshot = try await service.snapshot()
            try Task.checkCancellation()
            profiles = snapshot.profiles; policy = snapshot.policy; loaded = true; error = nil
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func remove(_ profile: SSHConnection) async {
        guard !busy else { return }; busy = true
        do { try await service.remove(profile); error = nil; status = AppCopy.current.text("已删除连接及保存的凭据。", "Connection and saved credential removed.") }
        catch {
            let message = error.localizedDescription
            busy = false; await load(); self.error = message; return
        }
        busy = false; await load()
    }
}

@MainActor @Observable
final class SSHConnectionDraft: Identifiable {
    typealias Authentication = SSHAuthentication
    let id: UUID
    let original: SSHConnection?
    var name: String
    var groupID: UUID?
    var host: String
    var port: String
    var username: String
    var fingerprint: String
    var authentication: Authentication
    var keyPath: String
    var agentSocketPath: String
    var jumpConnectionID: UUID?
    var keyHasPassphrase: Bool
    var secret = ""
    var verifiedHost: Bool
    var access: SSHAccess
    var fileRead: Bool
    var fileTransfer: Bool
    var fileManagement: Bool
    var expectedAccess: SSHAccountAccess?
    var busy = false
    var feedback = ""
    var error: String?
    init(profile: SSHConnection? = nil, policy: MCPPolicy = MCPPolicy()) {
        expectedAccess = profile.map { SSHAccountAccess(id: $0.id, policy: policy) }
        original = profile; id = profile?.id ?? UUID(); groupID = profile?.groupID
        name = profile?.name ?? ""; host = profile?.host ?? ""; port = String(profile?.port ?? 22)
        username = profile?.username ?? "root"; fingerprint = profile?.hostFingerprint ?? ""
        authentication = profile?.authenticationMethod ?? .password
        agentSocketPath = profile?.agentSocketPath ?? ""; jumpConnectionID = profile?.jumpConnectionID
        keyPath = profile?.privateKeyPath ?? ""; keyHasPassphrase = profile?.storesCredential ?? false
        verifiedHost = profile != nil; access = profile.map { SSHAccess.current(id: $0.id, policy: policy) } ?? .denied
        fileManagement = profile.map { policy.ssh?.fileManagementConnectionIDs.contains($0.id) == true } ?? false
        fileRead = profile.map { policy.ssh?.fileReadConnectionIDs.contains($0.id) == true } ?? false
        fileTransfer = profile.map { policy.ssh?.fileTransferConnectionIDs.contains($0.id) == true } ?? false
    }
    func synchronizeAccess(service: SSHConnectionService) async {
        guard let expectedAccess, !busy else { return }
        guard access == expectedAccess.access, fileRead == expectedAccess.fileRead, fileTransfer == expectedAccess.fileTransfer, fileManagement == expectedAccess.fileManagement else { return }
        guard let snapshot = try? await service.snapshot() else { return }
        guard !busy, access == expectedAccess.access, fileRead == expectedAccess.fileRead, fileTransfer == expectedAccess.fileTransfer, fileManagement == expectedAccess.fileManagement else { return }
        let value = SSHAccountAccess(id: id, policy: snapshot.policy)
        fileManagement = value.fileManagement
        self.expectedAccess = value; access = value.access; fileRead = value.fileRead; fileTransfer = value.fileTransfer
    }
    var retainsCredential: Bool {
        original?.storesCredential == true && original?.authenticationMethod == authentication && (authentication == .password || original?.privateKeyPath == keyPath)
    }
    func profile() throws -> SSHConnection {
        guard verifiedHost else { throw MCPFailure(AppCopy.current.text("请先核对并确认服务器指纹。", "Verify and confirm the host fingerprint first.")) }
        let profile = SSHConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            hostFingerprint: fingerprint.trimmingCharacters(in: .whitespacesAndNewlines),
            privateKeyPath: authentication == .privateKey ? keyPath : nil,
            storesCredential: authentication == .password || (authentication == .privateKey && keyHasPassphrase), authentication: authentication,
            agentSocketPath: authentication == .agent && !agentSocketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? agentSocketPath.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            jumpConnectionID: jumpConnectionID, groupID: groupID, sortIndex: original?.sortIndex)
        try profile.validate()
        guard !profile.storesCredential || !secret.isEmpty || retainsCredential else {
            throw MCPFailure(AppCopy.current.text("请输入密码或私钥口令。", "Enter a password or key passphrase."))
        }
        return profile
    }
    func readFingerprint(service: SSHConnectionService) async {
        guard !busy else { return }; busy = true; error = nil; feedback = ""
        defer { busy = false }
        do { fingerprint = try await service.fingerprint(host: host, port: Int(port) ?? 0, jumpConnectionID: jumpConnectionID); verifiedHost = false }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func test(service: SSHConnectionService) async {
        guard !busy else { return }; busy = true; error = nil; feedback = ""
        defer { busy = false }
        do {
            let profile = try profile()
            try await service.test(profile, secret: profile.storesCredential && !secret.isEmpty ? secret : nil)
            feedback = AppCopy.current.text("连接成功，服务器指纹及账号认证通过。", "Connected. Host fingerprint and account authentication verified.")
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func save(service: SSHConnectionService) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil; feedback = ""
        defer { busy = false }
        do {
            let profile = try profile()
            try await service.save(profile, original: original, secret: profile.storesCredential && !secret.isEmpty ? secret : nil,
                access: access, fileRead: fileRead, fileTransfer: fileTransfer, fileManagement: fileManagement, expectingAccess: expectedAccess)
            secret = ""; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
