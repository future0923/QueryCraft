import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHTransferProgressTests {
    private func setup(progress: Bool = true) throws -> (URL, SSHConnection, MCPRuntime, ProgressTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let profile = SSHConnection(id: UUID(), name: "progress fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: "/fixture/key", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true; policy.mode = .fullAccess
        policy.ssh = .init(connectionIDs: [profile.id], fileReadConnectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let transport = ProgressTransport(progress: progress)
        return (root, profile, MCPRuntime(directory: root, sshTransport: transport), transport)
    }
    private func args(_ profile: SSHConnection) -> [String: MCPJSONValue] {
        ["connection_id": .string(profile.id.uuidString), "direction": "upload", "local_path": "/fixture/local", "remote_path": "/fixture/remote", "confirm_high_risk": true]
    }
    @Test(.timeLimit(.minutes(1))) func asynchronousProgressAndResultSurviveReaderRestart() async throws {
        let (root, profile, owner, transport) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await owner.call("querycraft_ssh_start_transfer", arguments: args(profile))
        let id = try #require(accepted.objectValue?["transfer_id"]?.stringValue)
        let task = try #require(await owner.sshTransfers[UUID(uuidString: id)!])
        await transport.waitStarted()
        let reader = MCPRuntime(directory: root, sshTransport: ProgressTransport(progress: true))
        let query: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "transfer_id": .string(id)]
        let running = try await reader.call("querycraft_ssh_transfer_status", arguments: query)
        #expect(running.objectValue?["state"] == "running")
        #expect(running.objectValue?["bytes_transferred"] == 2)
        #expect(running.objectValue?["total_bytes"] == 4)
        #expect(running.objectValue?["result"] == .null)
        await transport.publishBeforeCompletion()
        let publishing = try await reader.call("querycraft_ssh_transfer_status", arguments: query)
        #expect(publishing.objectValue?["phase"] == "publishing")
        #expect(publishing.objectValue?["state"] == "running")
        #expect(publishing.objectValue?["bytes_transferred"] == 4)
        await transport.release(); await task.value
        await owner.shutdown(); await reader.shutdown()
        let restarted = MCPRuntime(directory: root, sshTransport: ProgressTransport(progress: false))
        let completed = try await restarted.call("querycraft_ssh_transfer_status", arguments: query)
        #expect(completed.objectValue?["state"] == "completed")
        #expect(completed.objectValue?["result"]?.objectValue?["sha256"] == .string(String(repeating: "a", count: 64)))
        let hidden = try await restarted.call("querycraft_ssh_list_transfers", arguments: ["connection_id": .string(profile.id.uuidString)])
        #expect(hidden.objectValue?["total_records"] == 0)
        var history: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString)]; history["include_completed"] = true
        let listed = try await restarted.call("querycraft_ssh_list_transfers", arguments: history)
        #expect(listed.objectValue?["total_records"] == 1)
        var forget = query; forget["confirm_high_risk"] = true
        _ = try await restarted.call("querycraft_ssh_forget_transfer", arguments: forget)
        #expect(try SSHTransferStore(directory: root).load().isEmpty)
        await restarted.shutdown()
    }
    @Test(.timeLimit(.minutes(1))) func cancellationIsARequestAndOldPluginDoesNotInventBytes() async throws {
        let (root, profile, runtime, transport) = try setup(progress: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try await runtime.call("querycraft_ssh_start_transfer", arguments: args(profile))
        let id = try #require(accepted.objectValue?["transfer_id"]?.stringValue)
        let task = try #require(await runtime.sshTransfers[UUID(uuidString: id)!])
        await transport.waitStarted()
        var query: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "transfer_id": .string(id)]
        let running = try await runtime.call("querycraft_ssh_transfer_status", arguments: query)
        #expect(running.objectValue?["bytes_transferred"] == .null)
        #expect(running.objectValue?["progress_available"] == false)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_cancel_transfer", arguments: query) }
        query["confirm_high_risk"] = true
        _ = try await runtime.call("querycraft_ssh_cancel_transfer", arguments: query)
        await task.value
        query.removeValue(forKey: "confirm_high_risk")
        let stopped = try await runtime.call("querycraft_ssh_transfer_status", arguments: query)
        #expect(stopped.objectValue?["state"] == "cancelled")
        #expect(stopped.objectValue?["destination_outcome"] == "unknown")
        query["confirm_high_risk"] = true
        let finalQuery = query
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_forget_transfer", arguments: finalQuery) }
        await runtime.shutdown()
    }
    @Test(.timeLimit(.minutes(1))) func ownerShutdownCancelsBackgroundWorkAndCapacityDoesNotLeakRecords() async throws {
        let (root, profile, runtime, transport) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let policyStore = MCPPolicyStore(directory: root)
        var policy = try policyStore.load(); policy.maximumSessions = 1; try policyStore.save(policy)
        let accepted = try await runtime.call("querycraft_ssh_start_transfer", arguments: args(profile))
        let id = try #require(accepted.objectValue?["transfer_id"]?.stringValue)
        await transport.waitStarted()
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_start_transfer", arguments: args(profile)) }
        #expect(try SSHTransferStore(directory: root).load().count == 1)
        await runtime.shutdown()
        #expect(await runtime.sshTransfers.isEmpty)
        #expect(await runtime.sshOperations.isEmpty)
        policy.mode = .readOnly; try policyStore.save(policy)
        let reader = MCPRuntime(directory: root, sshTransport: ProgressTransport(progress: false))
        let state = try await reader.call("querycraft_ssh_transfer_status", arguments: ["connection_id": .string(profile.id.uuidString), "transfer_id": .string(id)])
        #expect(state.objectValue?["state"] == "cancelled")
        #expect(state.objectValue?["bytes_transferred"] == 2)
        #expect(try !SSHTransferStore(directory: root).isActive(UUID(uuidString: id)!, transferOwner: true))
        await reader.shutdown()
    }
    @Test func trackingRespectsUnderlyingDownloadGrantsAndDisabledTools() async throws {
        let (root, profile, runtime, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPPolicyStore(directory: root)
        var policy = try store.load(); policy.ssh?.fileReadConnectionIDs = []; try store.save(policy)
        var download = args(profile); download["direction"] = "download"
        let denied = download
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_start_transfer", arguments: denied) }
        policy.disabledTools.insert("ssh_upload_file"); try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_start_transfer", arguments: args(profile)) }
        #expect(try SSHTransferStore(directory: root).load().isEmpty)
        await runtime.shutdown()
    }
    @Test func missingOwnerIsUnknownAndRetentionNeverDropsUnresolvedRecords() throws {
        let (root, profile, _, _) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SSHTransferStore(directory: root)
        func record() -> SSHTransferRecord {
            let id = UUID()
            return .init(id: id, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), upload: false, remotePath: "/fixture/file", localPath: "/fixture/local", stagingPath: SSHTransferRecord.stagingPath(destination: "/fixture/local", id: id), createdAt: Date())
        }
        let orphan = record(); try store.insert(orphan)
        let operation = try store.operationLock(orphan.id)
        let recorder = try SSHTransferRecorder(store: store, id: orphan.id, progressAvailable: true)
        recorder.receive(.init(phase: .transferring, transferred: 2, total: 4))
        #expect(try store.status(orphan).state == .unknown)
        #expect(try store.status(orphan).bytes == 2)
        let complete = record()
        var completeLock: MCPComponentLock? = try store.operationLock(complete.id)
        try store.saveStatus(.init(state: .completed, phase: "finished", progressAvailable: true, result: .object(["status": "completed"])), id: complete.id)
        let records = [orphan, complete] + (0..<510).map { _ in record() }
        try JSONEncoder().encode(records).write(to: store.url)
        // Release only the completed entry lock before it can be retained away.
        withExtendedLifetime((operation, completeLock)) {}
        completeLock = nil
        let added = record(); try store.insert(added)
        let loaded = try store.load()
        #expect(loaded.count == 512)
        #expect(loaded.contains { $0.id == orphan.id })
        #expect(!loaded.contains { $0.id == complete.id })
    }
}

private actor ProgressTransport: SSHTransport {
    nonisolated let supportsFiles = true
    nonisolated let supportsFileManagement = true
    nonisolated let supportsTransferProgress: Bool
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var receive: (@Sendable (SSHTransferProgress) -> Void)?
    init(progress: Bool) { supportsTransferProgress = progress; (stream, continuation) = AsyncStream.makeStream() }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func publishBeforeCompletion() { receive?(.init(phase: .publishing, transferred: 4, total: 4)) }
    func release() { continuation.finish() }
    func execute(_ request: SSHRequest) async throws -> SSHResult { throw MCPFailure("Unexpected command") }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        if supportsTransferProgress { receive = file.progress; receive?(.init(phase: .transferring, transferred: 2, total: 4)) }
        started = true; for waiter in waiters { waiter.resume() }; waiters.removeAll()
        for await _ in stream {}
        try Task.checkCancellation()
        return .init(exitStatus: 0, stdout: Data(String(repeating: "a", count: 64).utf8), outputBytes: 4)
    }
}
