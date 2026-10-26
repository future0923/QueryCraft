import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPSSHTests {
    private func profile() -> SSHConnection {
        SSHConnection(id: UUID(), name: "SSH fixture", host: "127.0.0.1", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/private-key", storesCredential: false)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "qc-ssh-" + UUID().uuidString) }
    private func policy(_ profile: SSHConnection, execution: Bool = false) -> MCPPolicy {
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = MCPSSHPolicy(connectionIDs: [profile.id], executionConnectionIDs: execution ? [profile.id] : [])
        return policy
    }
    private func args(_ profile: SSHConnection) -> [String: MCPJSONValue] {
        ["connection_id": .string(profile.id.uuidString), "command": "printf fixture", "confirm_high_risk": true]
    }

    @Test func databaseGrantsNeverAuthorizeShellExecution() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), transport = RecordingSSHTransport()
        try SSHConnectionStore(directory: directory).insert(profile)
        var permission = MCPPolicy(); permission.enabled = true; permission.allConnections = true
        try MCPPolicyStore(directory: directory).save(permission)
        let runtime = MCPRuntime(directory: directory, sshTransport: transport)
        let list = try await runtime.call("querycraft_ssh_list_connections", arguments: [:])
        #expect(list.arrayValue?.isEmpty == true)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args(profile)) }
        #expect(await transport.requests.isEmpty)
        permission = policy(profile); try MCPPolicyStore(directory: directory).save(permission)
        _ = try await runtime.call("querycraft_ssh_test_connection", arguments: ["connection_id": .string(profile.id.uuidString)])
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args(profile)) }
        #expect(await transport.requests.count == 1)
        await runtime.shutdown()
    }

    @Test func executeRequiresAccountGrantToolEnabledAndConfirmationThroughBothRoutes() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), transport = RecordingSSHTransport()
        try SSHConnectionStore(directory: directory).insert(profile)
        var permission = policy(profile, execution: true)
        try MCPPolicyStore(directory: directory).save(permission)
        let runtime = MCPRuntime(directory: directory, sshTransport: transport)
        var command = args(profile); command["confirm_high_risk"] = false
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: command) }
        let indirect: [String: MCPJSONValue] = ["plugin_id": "ssh", "tool": "ssh_execute", "arguments": .object(command)]
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_plugin_call", arguments: indirect) }
        permission.ssh?.executionConnectionIDs = []; try MCPPolicyStore(directory: directory).save(permission)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args(profile)) }
        permission.ssh?.executionConnectionIDs = [profile.id]; permission.disabledTools = ["ssh_execute"]
        try MCPPolicyStore(directory: directory).save(permission)
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_plugin_call", arguments: ["plugin_id": "ssh", "tool": "ssh_execute", "arguments": .object(args(profile))])
        }
        #expect(await transport.requests.isEmpty)
        permission.disabledTools = []; try MCPPolicyStore(directory: directory).save(permission)
        let result = try await runtime.call("querycraft_plugin_call", arguments: ["plugin_id": "ssh", "tool": "ssh_execute", "arguments": .object(args(profile))])
        #expect(result.objectValue?["stdout"] == "fixture")
        #expect(result.objectValue?["exit_code"] == 0)
        #expect(await transport.requests.count == 1)
        await runtime.shutdown()
    }

    @Test func savedSecretsStayOutOfConfigurationAndAuthorization() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), credentials = InMemoryCredentialStore()
        var permission = MCPPolicy(); permission.enabled = true; permission.allConnections = true
        try MCPPolicyStore(directory: directory).save(permission)
        let runtime = MCPRuntime(directory: directory, credentials: credentials, sshTransport: RecordingSSHTransport())
        let result = try await runtime.call("querycraft_ssh_add_connection", arguments: [
            "name": "saved", "host": "localhost", "username": "fixture", "host_fingerprint": .string(profile.hostFingerprint), "password": "fixture-only-secret"])
        let id = try #require(result.objectValue?["connection_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(result.objectValue?["authorized"] == false)
        #expect(try await credentials.password(for: id) == "fixture-only-secret")
        let store = SSHConnectionStore(directory: directory)
        #expect(try store.load().first?.storesCredential == true)
        #expect(!String(decoding: try Data(contentsOf: store.url), as: UTF8.self).contains("fixture-only-secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try MCPPolicyStore(directory: directory).load().ssh == nil)
        permission.ssh = MCPSSHPolicy(connectionIDs: [id])
        try MCPPolicyStore(directory: directory).save(permission)
        _ = try await runtime.call("querycraft_ssh_remove_connection", arguments: ["connection_id": .string(id.uuidString), "confirm_high_risk": true])
        #expect(try await credentials.password(for: id) == nil)
        #expect(try store.load().isEmpty)
        await runtime.shutdown()
    }

    @Test func hostFingerprintsAndAuthenticationAreValidatedBeforeSaving() throws {
        var profile = profile(); try profile.validate()
        profile.hostFingerprint = "SHA256:unverified"
        #expect(throws: MCPFailure.self) { try profile.validate() }
        profile = self.profile(); profile.privateKeyPath = "~/.ssh/id_ed25519"
        #expect(throws: MCPFailure.self) { try profile.validate() }
        profile = self.profile(); profile.privateKeyPath = nil
        #expect(throws: MCPFailure.self) { try profile.validate() }
        profile = self.profile(); profile.host += "\0other"
        #expect(throws: MCPFailure.self) { try profile.validate() }
    }

    @Test func toolDiscoveryAndResultBudgetsAreBounded() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), transport = RecordingSSHTransport()
        try SSHConnectionStore(directory: directory).insert(profile)
        var permission = policy(profile, execution: true); permission.queryTimeoutSeconds = 2
        permission.optimizations = .init(discovery: .lazy)
        try MCPPolicyStore(directory: directory).save(permission)
        let runtime = MCPRuntime(directory: directory, sshTransport: transport)
        let schemas = try await runtime.call("querycraft_plugin_tools", arguments: ["plugin_id": "ssh"])
        #expect(Set(schemas.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []) == MCPToolCatalog.sshTools.subtracting(MCPToolCatalog.sshFileReads.union(MCPToolCatalog.sshTransfers).union(MCPToolCatalog.sshFileWrites).union(MCPToolCatalog.sshRecoveryReads).union(MCPToolCatalog.sshRecoveryWrites)))
        let tools = try await runtime.tools()
        #expect(MCPToolCatalog.sshTools.subtracting(MCPToolCatalog.sshFileReads.union(MCPToolCatalog.sshTransfers).union(MCPToolCatalog.sshFileWrites).union(MCPToolCatalog.sshRecoveryReads).union(MCPToolCatalog.sshRecoveryWrites)).allSatisfy { name in tools.contains { $0.name == "querycraft_" + name } })
        permission.maximumResultBytes = 1024
        try MCPPolicyStore(directory: directory).save(permission)
        var command = args(profile); command["max_output_bytes"] = 1_048_576; command["timeout_seconds"] = 300
        _ = try await runtime.call("querycraft_ssh_execute", arguments: command)
        let request = try #require(await transport.requests.first)
        #expect(request.maximumOutputBytes <= (1024 - 768) / 6)
        #expect(request.timeoutMilliseconds == 2000)
        await runtime.shutdown()
    }

    @Test func revocationDuringCredentialReadPreventsExecution() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        var profile = profile(); profile.storesCredential = true
        try SSHConnectionStore(directory: directory).insert(profile)
        let credentials = PausedSSHCredentials(), transport = RecordingSSHTransport()
        var permission = policy(profile, execution: true)
        try MCPPolicyStore(directory: directory).save(permission)
        let runtime = MCPRuntime(directory: directory, credentials: credentials, sshTransport: transport)
        let command = args(profile)
        let operation = Task { try await runtime.call("querycraft_ssh_execute", arguments: command) }
        _ = await credentials.started.first { _ in true }
        permission.ssh = nil; try MCPPolicyStore(directory: directory).save(permission)
        await credentials.release()
        await #expect(throws: MCPFailure.self) { _ = try await operation.value }
        #expect(await transport.requests.isEmpty)
        await runtime.shutdown()
    }

    @Test func shutdownCancelsInFlightSSHWithoutRetrying() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), transport = RecordingSSHTransport(wait: true)
        try SSHConnectionStore(directory: directory).insert(profile)
        var permission = policy(profile, execution: true)
        permission.maximumSessions = 1; permission.allConnections = true
        try MCPPolicyStore(directory: directory).save(permission)
        let runtime = MCPRuntime(directory: directory, sshTransport: transport)
        let database = ConnectionProfile(id: UUID(), name: "capacity fixture", groupID: nil, databaseType: .mysql,
            host: "127.0.0.1", port: 3306, username: "fixture", defaultDatabase: "fixture", tlsMode: .disabled, storesCredential: false, createdAt: Date())
        try await runtime.repository.insert(database)
        let command = args(profile)
        let operation = Task { try await runtime.call("querycraft_ssh_execute", arguments: command) }
        _ = await transport.started.first { _ in true }
        do {
            _ = try await runtime.call("querycraft_list_databases", arguments: ["connection_id": .string(database.id.uuidString)])
            Issue.record("Database calls must share capacity with SSH operations")
        } catch let failure as MCPFailure { #expect(failure.code == .capacity) }
        await runtime.shutdown()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(await transport.requests.count == 1)
    }

    @Test func unknownOutcomeErrorsNeverExposeDriverSecrets() throws {
        for code: Int32 in [2, 3, 4, 5, 6, 7] {
            let result = SSHResult(status: code, commandMayHaveRun: true, stderr: Data("private-server-data".utf8))
            do { try result.validate(); Issue.record("Expected SSH failure") }
            catch let failure as MCPFailure {
                #expect(failure.message.contains("may have"))
                #expect(!failure.message.contains("private-server-data"))
                #expect(failure.value.objectValue?["error"]?.objectValue?["automatic_retry"] == false)
            }
        }
    }
}

actor RecordingSSHTransport: SSHTransport {
    var requests: [SSHRequest] = []
    let wait: Bool
    nonisolated let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init(wait: Bool = false) {
        self.wait = wait
        (started, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }
    func execute(_ request: SSHRequest) async throws -> SSHResult {
        requests.append(request); continuation.yield(())
        if wait { try await Task.sleep(for: .seconds(60)) }
        return SSHResult(exitStatus: request.command == nil ? -1 : 0, stdout: Data("fixture".utf8), outputBytes: 7)
    }
}

private actor PausedSSHCredentials: CredentialStore {
    nonisolated let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<String?, Never>?
    init() { (started, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1)) }
    func password(for profileID: UUID) async throws -> String? {
        await withCheckedContinuation { pending = $0; signal.yield(()) }
    }
    func release() { pending?.resume(returning: "fixture"); pending = nil }
    func save(password: String, for profileID: UUID) async throws {}
    func delete(for profileID: UUID) async throws {}
}
