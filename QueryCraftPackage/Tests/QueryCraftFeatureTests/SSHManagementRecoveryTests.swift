import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHManagementRecoveryTests {
    private func profile() -> SSHConnection {
        .init(id: UUID(), name: "management fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: "/fixture/key", storesCredential: false)
    }
    @Test func managementIsDefaultDenyAndIndependentOfTransfers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), transport = ManagementFixtureTransport()
        try SSHConnectionStore(directory: root).insert(profile)
        let old = try JSONSerialization.data(withJSONObject: ["connectionIDs": [profile.id.uuidString], "executionConnectionIDs": [profile.id.uuidString], "fileTransferConnectionIDs": [profile.id.uuidString]])
        let decoded = try JSONDecoder().decode(MCPSSHPolicy.self, from: old)
        #expect(decoded.fileManagementConnectionIDs.isEmpty)
        var policy = MCPPolicy(); policy.enabled = true; policy.ssh = decoded
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        let arguments: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "path": "/source", "destination_path": "/destination", "confirm_high_risk": true]
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_move_path", arguments: arguments) }
        policy.disabledTools = ["ssh_move_path"]; policy.ssh?.fileManagementConnectionIDs = [profile.id]; try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_move_path", arguments: arguments) }
        policy.disabledTools = []; try store.save(policy)
        var unconfirmed = arguments; unconfirmed["confirm_high_risk"] = false
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_move_path", arguments: unconfirmed) }
        #expect(await transport.files.isEmpty)
        let value = try await runtime.call("querycraft_ssh_move_path", arguments: arguments)
        #expect(value.objectValue?["destination_path"] == "/destination")
        #expect(await transport.files.first?.operation == .move)
        #expect(await transport.files.count == 1)
        for path in ["/", "/a/../b", "/a/./b", "/a//b", "/a/"] { #expect(throws: MCPFailure.self) { try SSHFileRequest.validateMutationPath(path) } }
        await runtime.shutdown()
    }
    @Test func trackedLocalCleanupChecksTokenAndPreservesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), transferID = UUID()
        try SSHConnectionStore(directory: root).insert(profile)
        let destination = root.appending(path: "destination.bin")
        try Data("destination".utf8).write(to: destination)
        let staging = SSHTransferRecord.stagingPath(destination: destination.path, id: transferID)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: staging))
        let records = SSHTransferStore(directory: root)
        try records.insert(.init(id: transferID, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), upload: false,
            remotePath: "/remote/source", localPath: destination.path, stagingPath: staging, createdAt: Date()))
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root, sshTransport: ManagementFixtureTransport())
        let args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "transfer_id": .string(transferID.uuidString)]
        let inspection = try await runtime.call("querycraft_ssh_inspect_transfer", arguments: args)
        let token = try #require(inspection.objectValue?["inspection_token"]?.stringValue)
        var clean = args; clean["inspection_token"] = .string(token); clean["confirm_high_risk"] = true; clean["acknowledge_outcome_unknown"] = true
        try Data("changed-partial".utf8).write(to: URL(fileURLWithPath: staging))
        let stale = clean
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_cleanup_transfer", arguments: stale) }
        #expect(FileManager.default.fileExists(atPath: staging))
        var lock: MCPComponentLock? = try records.operationLock(transferID)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_inspect_transfer", arguments: args) }
        withExtendedLifetime(lock) {}; lock = nil
        try FileManager.default.removeItem(atPath: staging)
        try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: destination.path)
        let symlinkInspection = try await runtime.call("querycraft_ssh_inspect_transfer", arguments: args)
        var unsafe = clean; unsafe["inspection_token"] = symlinkInspection.objectValue?["inspection_token"]
        let unsafeCleanup = unsafe
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_cleanup_transfer", arguments: unsafeCleanup) }
        try FileManager.default.removeItem(atPath: staging)
        try Data("partial".utf8).write(to: URL(fileURLWithPath: staging))
        let fresh = try await runtime.call("querycraft_ssh_inspect_transfer", arguments: args)
        clean["inspection_token"] = fresh.objectValue?["inspection_token"]
        let confirmed = clean
        _ = try await runtime.call("querycraft_ssh_cleanup_transfer", arguments: confirmed)
        #expect(!FileManager.default.fileExists(atPath: staging))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "destination")
        #expect(try records.load().isEmpty)
        await runtime.shutdown()
    }
    @Test func recoveryRecordsArePaginatedAndAccountScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), other = self.profile()
        try SSHConnectionStore(directory: root).insert(profile); try SSHConnectionStore(directory: root).insert(other)
        let records = SSHTransferStore(directory: root)
        for owner in [profile, profile, other] {
            let id = UUID(), path = root.appending(path: id.uuidString).path
            try records.insert(.init(id: id, connectionID: owner.id, binding: SSHTaskRecord.binding(owner), upload: false,
                remotePath: "/remote/file", localPath: path, stagingPath: SSHTransferRecord.stagingPath(destination: path, id: id), createdAt: Date()))
        }
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root, sshTransport: ManagementFixtureTransport())
        let arguments: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "max_records": 1]
        let first = try await runtime.call("querycraft_ssh_list_transfers", arguments: arguments)
        #expect(first.objectValue?["total_records"] == 2)
        #expect(first.objectValue?["next_offset"] == 1)
        var page = arguments; page["offset"] = 1
        let second = try await runtime.call("querycraft_ssh_list_transfers", arguments: page)
        #expect(first.objectValue?["transfers"] != second.objectValue?["transfers"])
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_list_transfers", arguments: ["connection_id": .string(other.id.uuidString)]) }
        await runtime.shutdown()
    }
    @Test func taskForgetIsAcknowledgedLocalOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), transport = ManagementFixtureTransport(), taskID = UUID()
        try SSHConnectionStore(directory: root).insert(profile)
        let records = SSHTaskStore(directory: root)
        try records.insert(.init(id: taskID, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), createdAt: Date()))
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], executionConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        var args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "task_id": .string(taskID.uuidString), "confirm_high_risk": true]
        let unacknowledged = args
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_forget_task", arguments: unacknowledged) }
        args["acknowledge_task_may_be_running"] = true
        var active: MCPComponentLock? = try MCPComponentLock(directory: root.appending(path: "SSHTaskOperations/" + taskID.uuidString))
        let acknowledged = args
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_forget_task", arguments: acknowledged) }
        withExtendedLifetime(active) {}; active = nil
        let result = try await runtime.call("querycraft_ssh_forget_task", arguments: args)
        #expect(result.objectValue?["remote_task_stopped"] == false)
        #expect(try records.load().isEmpty)
        #expect(await transport.commands == 0)
        await runtime.shutdown()
    }
}
private actor ManagementFixtureTransport: SSHTransport {
    nonisolated let supportsFiles = true
    nonisolated let supportsFileManagement = true
    var files: [SSHFileRequest] = []
    var commands = 0
    func execute(_ request: SSHRequest) async throws -> SSHResult { commands += 1; return .init(exitStatus: 0) }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult { files.append(file); return .init(exitStatus: 0) }
}
