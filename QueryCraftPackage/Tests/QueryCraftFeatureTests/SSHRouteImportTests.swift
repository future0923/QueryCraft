import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHRouteImportTests {
    private func profile(_ name: String = "fixture", parent: UUID? = nil, agent: Bool = false) -> SSHConnection {
        .init(id: UUID(), name: name, host: name + ".example", port: 22, username: "fixture", hostFingerprint: "SHA256:" + String(repeating: "A", count: 43),
            privateKeyPath: nil, storesCredential: !agent, authentication: agent ? .agent : nil,
            agentSocketPath: agent ? "/tmp/fixture-agent.sock" : nil, jumpConnectionID: parent)
    }
    @Test func legacyProfilesAndAgentValidationAreCompatible() throws {
        let legacy = profile(), data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SSHConnection.self, from: data)
        #expect(decoded.authenticationMethod == .password)
        #expect(decoded.jumpConnectionID == nil)
        var agent = profile(agent: true); try agent.validate()
        #expect(agent.value.objectValue?["authentication"] == "agent")
        agent.storesCredential = true
        #expect(throws: MCPFailure.self) { try agent.validate() }
        agent.storesCredential = false; agent.agentSocketPath = "relative/socket"
        #expect(throws: MCPFailure.self) { try agent.validate() }
        agent.agentSocketPath = nil
        #expect(throws: MCPFailure.self) { _ = try SSHRouteRequest.agentSocket(agent, environment: [:]) }
        #expect(try SSHRouteRequest.agentSocket(agent, environment: ["SSH_AUTH_SOCK": "/tmp/agent.sock"]) == "/tmp/agent.sock")
    }
    @Test func routeGraphRejectsCyclesMissingParentsExcessDepthAndDependentDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SSHConnectionStore(directory: root), jump = profile("jump"), target = profile("target", parent: jump.id)
        try store.insert(jump); try store.insert(target)
        #expect(try SSHConnectionStore.route(to: target, in: store.load()) == [jump])
        var cycle = jump; cycle.jumpConnectionID = target.id
        #expect(throws: MCPFailure.self) { try store.replace(cycle, expecting: jump) }
        #expect(throws: MCPFailure.self) { try store.remove(id: jump.id) }
        #expect(try store.load() == [jump, target])
        var chain = [jump, target]
        for index in 0..<4 { chain.append(profile("hop-\(index)", parent: chain.last!.id)) }
        #expect(throws: MCPFailure.self) { try SSHConnectionStore.validateRoutes(chain) }
        #expect(throws: MCPFailure.self) { try store.insert(profile("missing", parent: UUID())) }
    }
    @Test func routeMigrationKeepsPrivateBackupAndRejectsLegacyReaders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SSHConnectionStore(directory: root), jump = profile("jump"), target = profile("target")
        try store.insert(jump); try store.insert(target)
        let original = try Data(contentsOf: store.url)
        #expect(try JSONDecoder().decode([SSHConnection].self, from: original).count == 2)
        var routed = target; routed.jumpConnectionID = jump.id; try store.replace(routed, expecting: target)
        let extended = try Data(contentsOf: store.url)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode([SSHConnection].self, from: extended) }
        #expect(try store.load() == [jump, routed])
        let backup = root.appending(path: ".ssh-connections-v1.backup.json")
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.replace(target, expecting: routed)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode([SSHConnection].self, from: Data(contentsOf: store.url)) }
        #expect(try Data(contentsOf: backup) == original)
    }
    @Test func targetGrantsNeverAuthorizeJumpHostsAndRemovalPreservesDependentCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jump = profile("jump"), target = profile("target", parent: jump.id), credentials = RouteCredentials(), transport = RouteTransport()
        let accounts = SSHConnectionStore(directory: root); try accounts.insert(jump); try accounts.insert(target)
        try await credentials.save(password: "jump-secret", for: jump.id); try await credentials.save(password: "target-secret", for: target.id)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [target.id], executionConnectionIDs: [target.id])
        let policies = MCPPolicyStore(directory: root); try policies.save(policy)
        let runtime = MCPRuntime(directory: root, credentials: credentials, sshTransport: transport)
        let args: [String: MCPJSONValue] = ["connection_id": .string(target.id.uuidString), "command": "printf fixture", "confirm_high_risk": true]
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_ssh_execute", arguments: args) }
        #expect(await credentials.reads == 0)
        policy.ssh?.connectionIDs.insert(jump.id); try policies.save(policy)
        _ = try await runtime.call("querycraft_ssh_execute", arguments: args)
        let request = try #require(await transport.requests.first)
        #expect(request.jumps.map(\.connection.id) == [jump.id])
        #expect(request.jumps.first?.secret == "jump-secret")
        #expect(request.secret == "target-secret")
        #expect(policy.ssh?.executionConnectionIDs.contains(jump.id) == false)
        let service = SSHConnectionService(directory: root, credentials: credentials, transport: transport)
        await #expect(throws: MCPFailure.self) { try await service.remove(jump) }
        #expect(try await credentials.password(for: jump.id) == "jump-secret")
        #expect(try policies.load().ssh?.connectionIDs.contains(jump.id) == true)
        await runtime.shutdown()
    }
    @Test(.timeLimit(.minutes(1))) func jumpRevocationDuringCredentialAwaitPreventsSubmission() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jump = profile("jump"), target = profile("target", parent: jump.id), credentials = RouteCredentials(gated: true), transport = RouteTransport()
        let accounts = SSHConnectionStore(directory: root); try accounts.insert(jump); try accounts.insert(target)
        try await credentials.save(password: "jump", for: jump.id); try await credentials.save(password: "target", for: target.id)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [jump.id, target.id], executionConnectionIDs: [target.id])
        let policies = MCPPolicyStore(directory: root); try policies.save(policy)
        let runtime = MCPRuntime(directory: root, credentials: credentials, sshTransport: transport)
        let request = Task { try await runtime.call("querycraft_ssh_execute", arguments: ["connection_id": .string(target.id.uuidString), "command": "printf fixture", "confirm_high_risk": true]) }
        await credentials.waitStarted()
        policy.ssh?.connectionIDs.remove(jump.id); try policies.save(policy)
        await credentials.release()
        await #expect(throws: MCPFailure.self) { _ = try await request.value }
        #expect(await transport.requests.isEmpty)
        await runtime.shutdown()
    }
    @Test(.timeLimit(.minutes(1))) func observedHopRevocationCancelsAnActiveRouteWithoutReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jump = profile("jump"), target = profile("target", parent: jump.id), credentials = RouteCredentials(), transport = BlockingRouteTransport()
        let accounts = SSHConnectionStore(directory: root); try accounts.insert(jump); try accounts.insert(target)
        try await credentials.save(password: "jump", for: jump.id); try await credentials.save(password: "target", for: target.id)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [jump.id, target.id], executionConnectionIDs: [target.id])
        let policies = MCPPolicyStore(directory: root); try policies.save(policy)
        let runtime = MCPRuntime(directory: root, credentials: credentials, sshTransport: transport)
        let task = Task { try await runtime.call("querycraft_ssh_execute", arguments: ["connection_id": .string(target.id.uuidString), "command": "sleep 60", "confirm_high_risk": true]) }
        await transport.waitStarted()
        policy.ssh?.connectionIDs.remove(jump.id); try policies.save(policy)
        await runtime.reconcileSSHConnections()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.calls == 1)
        #expect(await runtime.sshOperations.isEmpty)
        await runtime.shutdown()
    }
    @Test func nativeFingerprintScanAuthenticatesOnlySavedJumps() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jump = profile("jump"), credentials = RouteCredentials(), transport = RouteTransport()
        try SSHConnectionStore(directory: root).insert(jump); try await credentials.save(password: "jump-secret", for: jump.id)
        let service = SSHConnectionService(directory: root, credentials: credentials, transport: transport)
        let fingerprint = try await service.fingerprint(host: "target.example", port: 2222, jumpConnectionID: jump.id)
        #expect(fingerprint == jump.hostFingerprint)
        let request = try #require(await transport.requests.first)
        #expect(request.scanHostKey)
        #expect(request.secret == nil)
        #expect(request.command == nil)
        #expect(request.jumps.first?.secret == "jump-secret")
        #expect(await credentials.reads == 1)
    }
    @Test func importResolvesFirstValuesNegationIncludesQuotesAndTokens() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".ssh/conf.d"), withIntermediateDirectories: true)
        try "Host db\n HostName db.internal\n User \"data user\"\n IdentityFile \"~/.ssh/id_%h_%p\"\nHost excluded\n HostName other.internal\n".write(to: root.appending(path: ".ssh/conf.d/one.conf"), atomically: true, encoding: .utf8)
        let config = """
        Include conf.d/*.conf
        Port=2222
        Host db
          HostName ignored.internal
        Host * !excluded
          User fallback
        Host excluded
          User separate
        Host jump
          HostName jump.internal
          IdentityAgent "${AGENT}"
        Host target
          HostName app.internal
          ProxyJump jump
        """
        let path = root.appending(path: ".ssh/config"); try config.write(to: path, atomically: true, encoding: .utf8)
        let preview = try SSHConfigImporter(home: root, username: "local", environment: ["AGENT": "/tmp/agent.sock"]).preview(path: path.path)
        let db = try #require(preview.candidates.first { $0.id == "db" })
        #expect(db.endpoint.host == "db.internal")
        #expect(db.endpoint.username == "data user")
        #expect(db.endpoint.port == 2222)
        #expect(db.keyPath == root.appending(path: ".ssh/id_db.internal_2222").path)
        #expect(!db.blocked)
        #expect(preview.candidates.first { $0.id == "excluded" }?.endpoint.username == "separate")
        let jump = try #require(preview.candidates.first { $0.id == "jump" })
        #expect(jump.authentication == .agent)
        #expect(jump.agentSocketPath == "/tmp/agent.sock")
        #expect(preview.candidates.first { $0.id == "target" }?.jumps.first?.host == "jump.internal")
        #expect(SSHConfigImporter.matches("DB", patterns: ["*", "!test"]))
        #expect(!SSHConfigImporter.matches("test", patterns: ["*", "!test"]))
    }
    @Test func importNeverExecutesCommandsAndBlocksUnsupportedOrCyclicRules() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appending(path: "config"), marker = root.appending(path: "must-not-exist")
        try "Host unsafe\n ProxyCommand touch \(marker.path)\n LocalCommand touch \(marker.path)\nHost match\nMatch exec \"touch \(marker.path)\"\n User ignored\n".write(to: config, atomically: true, encoding: .utf8)
        let preview = try SSHConfigImporter().preview(path: config.path)
        #expect(preview.candidates.allSatisfy { $0.blocked })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try "Host a\n ProxyJump b\nHost b\n ProxyJump a\n".write(to: config, atomically: true, encoding: .utf8)
        let blockedPreview = try SSHConfigImporter().preview(path: config.path)
        #expect(blockedPreview.candidates.allSatisfy { $0.blocked })
        try "Include \(config.path)\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(throws: MCPFailure.self) { _ = try SSHConfigImporter().preview(path: config.path) }
        try "Host bad\n Port invalid\nHost token\n IdentityFile ~/.ssh/id_%C\n".write(to: config, atomically: true, encoding: .utf8)
        let invalidPreview = try SSHConfigImporter().preview(path: config.path)
        #expect(invalidPreview.candidates.allSatisfy { $0.blocked })
    }
    @MainActor @Test func importRequiresSavedJumpAndStillStartsWithNoTrustOrGrants() throws {
        let jump = profile("bastion"), endpoint = SSHConfigEndpoint(alias: jump.name, host: jump.host, port: jump.port, username: jump.username)
        let candidate = SSHConfigCandidate(endpoint: .init(alias: "app", host: "app.example", port: 22, username: "app"),
            authentication: .agent, keyPath: nil, agentSocketPath: nil, jumps: [endpoint], warnings: [], blocked: false)
        #expect(throws: MCPFailure.self) { _ = try candidate.jumpID(in: []) }
        let model = SSHConfigImportModel(); model.preview = .init(candidates: [candidate], warnings: []); model.selection = candidate.id; model.profiles = [jump]
        let draft = try model.draft()
        #expect(draft.original == nil)
        #expect(draft.jumpConnectionID == jump.id)
        #expect(draft.authentication == .agent)
        #expect(!draft.verifiedHost)
        #expect(draft.access == .denied)
        #expect(!draft.fileRead && !draft.fileTransfer && !draft.fileManagement)
    }
}
private actor RouteCredentials: CredentialStore {
    var values: [UUID: String] = [:]
    var reads = 0
    private let gated: Bool
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    init(gated: Bool = false) { self.gated = gated }
    func password(for id: UUID) async throws -> String? {
        reads += 1
        if gated && !started {
            started = true; for waiter in waiters { waiter.resume() }; waiters.removeAll()
            await withCheckedContinuation { gate = $0 }
        }
        return values[id]
    }
    func save(password: String, for id: UUID) async throws { values[id] = password }
    func delete(for id: UUID) async throws { values.removeValue(forKey: id) }
    func waitStarted() async { if started { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { gate?.resume(); gate = nil }
}
private actor RouteTransport: SSHTransport {
    nonisolated let supportsRoutes = true
    var requests: [SSHRequest] = []
    func execute(_ request: SSHRequest) async throws -> SSHResult {
        requests.append(request)
        return .init(exitStatus: request.scanHostKey ? -1 : 0,
            stdout: request.scanHostKey ? Data(("SHA256:" + String(repeating: "A", count: 43)).utf8) : Data("fixture".utf8))
    }
}

private actor BlockingRouteTransport: SSHTransport {
    nonisolated let supportsRoutes = true
    var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let stream = AsyncStream<Void> { _ in }
    func waitStarted() async { if calls > 0 { return }; await withCheckedContinuation { waiters.append($0) } }
    func execute(_ request: SSHRequest) async throws -> SSHResult {
        calls += 1; for waiter in waiters { waiter.resume() }; waiters.removeAll()
        for await _ in stream {}
        try Task.checkCancellation(); return .init(exitStatus: 0)
    }
}
