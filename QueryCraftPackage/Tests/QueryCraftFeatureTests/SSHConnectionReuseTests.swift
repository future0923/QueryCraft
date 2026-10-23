import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHConnectionReuseTests {
    private func fixture(_ root: URL) throws -> SSHConnection {
        let profile = SSHConnection(id: UUID(), name: "reuse fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/key", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true; policy.mode = .fullAccess
        policy.ssh = .init(connectionIDs: [profile.id], executionConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        return profile
    }
    @Test func policyAndProfileChangesRetirePoolBeforeNextOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixture(root), transport = ReuseFixtureTransport(), runtime = MCPRuntime(directory: root, sshTransport: transport)
        let args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "command": "printf fixture", "confirm_high_risk": true]
        _ = try await runtime.call("querycraft_ssh_execute", arguments: args)
        _ = try await runtime.call("querycraft_ssh_execute", arguments: args)
        #expect(await transport.events == ["invalidate", "execute", "execute"])
        try MCPPolicyStore(directory: root).update { $0.mode = .readOnly }
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args) }
        #expect(await transport.events == ["invalidate", "execute", "execute", "invalidate"])
        try MCPPolicyStore(directory: root).update { $0.mode = .fullAccess }
        var changed = profile; changed.host = "changed-host"
        try SSHConnectionStore(directory: root).replace(changed, expecting: profile)
        _ = try await runtime.call("querycraft_ssh_execute", arguments: args)
        #expect(await transport.events.suffix(2) == ["invalidate", "execute"])
        try MCPPolicyStore(directory: root).update { $0.enabled = false }
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args) }
        #expect(await transport.events.last == "invalidate")
        await runtime.shutdown()
        #expect(await transport.events.last == "invalidate")
    }
    @Test(.timeLimit(.minutes(1))) func concurrentCallCannotPassUnfinishedPoolInvalidation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixture(root), transport = ReuseFixtureTransport(blockFirst: true)
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        let args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "command": "printf fixture", "confirm_high_risk": true]
        let first = Task { try await runtime.call("querycraft_ssh_execute", arguments: args) }
        await transport.waitForInvalidation()
        let second = Task { try await runtime.call("querycraft_ssh_execute", arguments: args) }
        #expect(await transport.events == ["invalidate"])
        await transport.releaseInvalidation()
        _ = try await first.value; _ = try await second.value
        #expect(await transport.events == ["invalidate", "execute", "execute"])
        await runtime.shutdown()
    }
    @Test func poolFailureIsNotAutomaticallyReplayed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try fixture(root), transport = ReuseFixtureTransport(fails: true)
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        let args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "command": "printf fixture", "confirm_high_risk": true]
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args) }
        #expect(await transport.events.filter { $0 == "execute" }.count == 1)
        await runtime.shutdown()
    }
}

private actor ReuseFixtureTransport: SSHTransport {
    var events: [String] = []
    var blockFirst = false
    let fails: Bool
    var blocked: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    init(blockFirst: Bool = false, fails: Bool = false) { self.blockFirst = blockFirst; self.fails = fails }
    func execute(_ request: SSHRequest) async throws -> SSHResult {
        events.append("execute")
        return fails ? SSHResult(status: 7, commandMayHaveRun: true) : SSHResult(exitStatus: 0)
    }
    func invalidate(connectionID: UUID?) async {
        events.append("invalidate")
        if blockFirst {
            blockFirst = false
            await withCheckedContinuation { blocked = $0; waiter?.resume(); waiter = nil }
        }
    }
    func waitForInvalidation() async { if blocked == nil { await withCheckedContinuation { waiter = $0 } } }
    func releaseInvalidation() { blocked?.resume(); blocked = nil }
}
