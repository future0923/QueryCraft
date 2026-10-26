import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHFilesTasksTests {
    private func profile() -> SSHConnection {
        .init(id: UUID(), name: "file fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: "/fixture/key", storesCredential: false)
    }
    @Test func oldPolicyDoesNotGrantNewFileAccess() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["connectionIDs": [id.uuidString], "executionConnectionIDs": [id.uuidString]])
        let policy = try JSONDecoder().decode(MCPSSHPolicy.self, from: data)
        #expect(policy.connectionIDs == [id]); #expect(policy.executionConnectionIDs == [id])
        #expect(policy.fileReadConnectionIDs.isEmpty && policy.fileTransferConnectionIDs.isEmpty)
    }
    @Test func readAndTransferGrantsAreIndependentOfShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), transport = FileFixtureTransport()
        try SSHConnectionStore(directory: directory).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], executionConnectionIDs: [profile.id])
        let store = MCPPolicyStore(directory: directory); try store.save(policy)
        let runtime = MCPRuntime(directory: directory, sshTransport: transport)
        let path: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "path": "/fixture"]
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_stat_file", arguments: path) }
        policy.ssh?.executionConnectionIDs = []; policy.ssh?.fileReadConnectionIDs = [profile.id]; try store.save(policy)
        let stat = try await runtime.call("querycraft_ssh_stat_file", arguments: path)
        #expect(stat.objectValue?["size_bytes"] == 3)
        let transfer: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "local_path": "/local", "remote_path": "/remote", "confirm_high_risk": true]
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_download_file", arguments: transfer) }
        policy.disabledTools = ["ssh_download_file"]; policy.ssh?.fileTransferConnectionIDs = [profile.id]; try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_download_file", arguments: transfer) }
        policy.disabledTools = []; try store.save(policy)
        _ = try await runtime.call("querycraft_ssh_download_file", arguments: transfer)
        policy.ssh?.fileReadConnectionIDs = []; try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_download_file", arguments: transfer) }
        #expect(await transport.fileRequests.count == 2)
        SSHAccess.denied.apply(id: profile.id, to: &policy)
        #expect(policy.ssh?.fileTransferConnectionIDs.isEmpty == true)
        await runtime.shutdown()
    }
    @Test func binaryReadIsLosslessAndInvalidUTF8IsExplicit() throws {
        var file = SSHFileRequest(operation: .read, remotePath: "/binary"); file.offset = 7
        let result = SSHResult(truncated: true, stdout: Data([0xff, 0, 0x80]), stderr: Data("13\t100\t33152\t123\n".utf8))
        #expect(throws: MCPFailure.self) { _ = try file.result(result) }
        let value = try file.result(result, encoding: "base64").objectValue
        #expect(value?["content"] == .string(Data([0xff, 0, 0x80]).base64EncodedString()))
        #expect(value?["next_offset"] == 10)
        #expect(value?["permissions"] == "600")
        #expect(throws: MCPFailure.self) { _ = try file.result(.init(stderr: Data("bad".utf8)), encoding: "base64") }
    }
    @Test func directoryNamesAndPaginationRespectBudget() throws {
        let file = SSHFileRequest(operation: .list, remotePath: "/dir")
        let name = Data("quotes'\n雪".utf8).base64EncodedString()
        let result = try file.result(.init(truncated: true, stdout: Data("\(name)\t13\t3\t33152\t123\n".utf8))).objectValue
        #expect(result?["next_offset"] == 1)
        #expect(result?["entries"]?.arrayValue?.first?.objectValue?["name"] == "quotes'\n雪")
        #expect(throws: MCPFailure.self) { _ = try file.result(.init(truncated: true)) }
    }
    @Test func taskRegistryBindsToAccountIdentityAndSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), store = SSHTaskStore(directory: directory)
        let record = SSHTaskRecord(id: UUID(), connectionID: profile.id, binding: SSHTaskRecord.binding(profile), createdAt: Date())
        try store.insert(record)
        let loaded = try #require(SSHTaskStore(directory: directory).load().first)
        #expect(loaded.matches(profile))
        var changed = profile; changed.name = "renamed"; changed.storesCredential = true
        #expect(loaded.matches(changed))
        changed.host = "other-host"; #expect(!loaded.matches(changed))
        changed = profile; changed.username = "other-user"; #expect(!loaded.matches(changed))
        #expect((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.remove(record.id); #expect(try store.load().isEmpty)
    }
    @Test func missingSystemToolsCreatesNoRecordAndUnknownLaunchRemainsDiscoverable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile()
        try SSHConnectionStore(directory: directory).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], executionConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: directory).save(policy)
        let arguments: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "command": "sleep 10", "confirm_high_risk": true]
        let unavailable = MCPRuntime(directory: directory, sshTransport: TaskFixtureTransport(missing: true))
        await #expect(throws: MCPFailure.self) { _ = try await unavailable.call("querycraft_ssh_start_task", arguments: arguments) }
        #expect(try SSHTaskStore(directory: directory).load().isEmpty)
        await unavailable.shutdown()
        let unknown = MCPRuntime(directory: directory, sshTransport: TaskFixtureTransport(missing: false))
        let result = try await unknown.call("querycraft_ssh_start_task", arguments: arguments)
        #expect(result.objectValue?["state"] == "unknown")
        let id = try #require(result.objectValue?["task_id"]?.stringValue)
        await unknown.shutdown()
        let restarted = MCPRuntime(directory: directory, sshTransport: TaskFixtureTransport(missing: false))
        let list = try await restarted.call("querycraft_ssh_list_tasks", arguments: ["connection_id": .string(profile.id.uuidString)])
        #expect(list.arrayValue?.first?.objectValue?["task_id"] == .string(id))
        await restarted.shutdown()
    }
    @Test func supervisorCommandQuotesPayloadWithoutShellExpansion() throws {
        let command = try SSHTaskCommand.make(action: "start", id: UUID(), payload: ["command": "echo '$HOME'; echo `id`; echo 雪"])
        #expect(!command.contains("python"))
        #expect(command.hasPrefix("/bin/bash -c "))
        #expect(command.utf8.count < 65_536)
        #expect(try SSHTaskCommand.make(action: "start", id: UUID(), payload: ["command": .string(String(repeating: "a", count: 16_384))]).utf8.count < 65_536)
        #expect(!command.contains("echo '$HOME'"))
        #expect(SSHTaskCommand.shellQuote("a'b") == "'a'\"'\"'b'")
    }
}
private actor FileFixtureTransport: SSHTransport {
    nonisolated let supportsFiles = true
    var fileRequests: [SSHFileRequest] = []
    func execute(_ request: SSHRequest) async throws -> SSHResult { .init() }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        fileRequests.append(file)
        if file.operation == .download { return .init(exitStatus: 0, stdout: Data(String(repeating: "a", count: 64).utf8), outputBytes: 3) }
        return .init(exitStatus: 0, stderr: Data("13\t3\t33152\t123\n".utf8))
    }
}

private actor TaskFixtureTransport: SSHTransport {
    let missing: Bool
    var calls = 0
    init(missing: Bool) { self.missing = missing }
    func execute(_ request: SSHRequest) async throws -> SSHResult {
        calls += 1
        if calls == 1 { return .init(exitStatus: missing ? 127 : 0) }
        return .init(status: 5, commandMayHaveRun: true)
    }
}
