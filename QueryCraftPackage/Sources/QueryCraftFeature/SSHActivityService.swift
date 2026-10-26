import Foundation

struct SSHActivityTransfer: Identifiable, Sendable {
    let record: SSHTransferRecord
    let active: Bool
    let cancellationRequested: Bool
    var id: UUID { record.id }
}

struct SSHActivitySnapshot: Sendable {
    var tasks: [SSHTaskRecord] = []
    var transfers: [SSHActivityTransfer] = []
    var allowedTools: Set<String> = []
    var policyEnabled = false
    var pluginAvailable = false
}

protocol SSHActivityServing: Sendable {
    func snapshot() async throws -> SSHActivitySnapshot
    func call(_ tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue
    func cancelTransfer(_ id: UUID) async throws
    func close() async
}

/// A local consumer of the same operations as stdio. No HTTP bridge or second account store.
actor SSHActivityService: SSHActivityServing {
    let directory: URL
    let profile: SSHConnection
    private let runtime: MCPRuntime
    init(directory: URL, profile: SSHConnection, credentials: (any CredentialStore)? = nil,
         transport: (any SSHTransport)? = nil) {
        self.directory = directory; self.profile = profile
        runtime = MCPRuntime(directory: directory,
            credentials: credentials ?? KeychainCredentialStore(directory: directory, allowsInteraction: true), sshTransport: transport)
    }
    private func currentProfile() throws -> SSHConnection {
        guard let current = try SSHConnectionStore(directory: directory).load().first(where: { $0.id == profile.id }),
              SSHTaskRecord.binding(current) == SSHTaskRecord.binding(profile) else {
            throw MCPFailure(AppCopy.current.text("服务器账号已变化，请关闭面板后重新打开。", "The server account changed. Close and reopen this panel."), code: .connectionNotFound)
        }
        return current
    }
    func snapshot() async throws -> SSHActivitySnapshot {
        let current = try currentProfile(), policy = try MCPPolicyStore(directory: directory).load()
        var snapshot = SSHActivitySnapshot()
        snapshot.policyEnabled = policy.enabled
        let available = await runtime.availableSSHTools
        snapshot.pluginAvailable = !available.isEmpty
        for tool in available where await runtime.sshPermitted(current, tool: tool, policy: policy) {
            snapshot.allowedTools.insert(tool)
        }
        snapshot.tasks = try SSHTaskStore(directory: directory).load().filter { $0.matches(current) }.sorted { $0.createdAt > $1.createdAt }
        let store = SSHTransferStore(directory: directory)
        snapshot.transfers = try store.load().filter { $0.matches(current) }.sorted { $0.createdAt > $1.createdAt }.map {
            SSHActivityTransfer(record: $0, active: try store.isActive($0.id, transferOwner: $0.cancellationVersion == 1), cancellationRequested: store.cancellationRequested($0.id))
        }
        return snapshot
    }
    func call(_ tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        _ = try currentProfile()
        guard MCPToolCatalog.sshTaskReads.union(MCPToolCatalog.sshTaskWrites)
            .union(MCPToolCatalog.sshRecoveryReads).union(MCPToolCatalog.sshRecoveryWrites).contains(tool) else { throw MCPFailure("Unavailable activity operation.") }
        var args = arguments; args["connection_id"] = .string(profile.id.uuidString)
        await runtime.startMaintenance()
        return try await runtime.call("querycraft_" + tool, arguments: args)
    }
    func cancelTransfer(_ id: UUID) async throws {
        let current = try currentProfile(), policy = try MCPPolicyStore(directory: directory).load()
        let records = SSHTransferStore(directory: directory)
        guard let record = try records.load().first(where: { $0.id == id && $0.matches(current) }) else { throw MCPFailure("Transfer not found.", code: .connectionNotFound) }
        let tool = record.upload ? "ssh_upload_file" : "ssh_download_file"
        try policy.authorize(tool: tool)
        guard await runtime.sshPermitted(current, tool: tool, policy: policy) else { throw MCPFailure("Transfer cancellation requires the current transfer grant and full access.", code: .accessDenied) }
        try records.requestCancellation(record)
    }
    func close() async { await runtime.shutdown() }
}
