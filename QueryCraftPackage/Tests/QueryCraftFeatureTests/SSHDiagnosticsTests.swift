import Foundation
import Testing
import CQueryCraftSSHPluginAPI
@testable import QueryCraftFeature

struct SSHDiagnosticsTests {
    private func profile() -> SSHConnection {
        .init(id: UUID(), name: "secret-name", host: "private.example", port: 22, username: "private-user",
              hostFingerprint: "SHA256:" + String(repeating: "A", count: 43), privateKeyPath: "/fixture/key", storesCredential: false)
    }
    @Test func diagnosticsBindForwardingToExactDestinationAndPreviousHopWithoutSecrets() throws {
        let endpoints = [profile(), profile(), profile()]
        var raw = qc_ssh_diagnostic(size: UInt32(MemoryLayout<qc_ssh_diagnostic>.size), endpoint_index: 2, hop_count: 2, phase: 7)
        let diagnostic = try #require(SSHDiagnostic(raw, endpoints: endpoints))
        let result = SSHResult(status: Int32(QC_SSH_CONNECT), diagnostic: diagnostic)
        do { try result.validate(); Issue.record("Expected forwarding failure") }
        catch let error as MCPFailure {
            #expect(error.code == .driverFailure)
            let ssh = error.value.objectValue?["error"]?.objectValue?["details"]?.objectValue?["ssh"]?.objectValue
            #expect(ssh?["connection_id"] == .string(endpoints[1].id.uuidString))
            #expect(ssh?["via_connection_id"] == .string(endpoints[0].id.uuidString))
            #expect(ssh?["phase"] == "forwarding")
            #expect(ssh?["role"] == "jump")
            let text = String(decoding: try JSONEncoder().encode(error.value), as: UTF8.self)
            #expect(!text.contains("secret-name") && !text.contains("private-user") && !text.contains("private.example"))
            #expect(error.message.contains("endpoint 2/3"))
        }
        raw.endpoint_index = 3; raw.phase = 5
        let target = try #require(SSHDiagnostic(raw, endpoints: endpoints))
        #expect(target.value.objectValue?["role"] == "target")
        #expect(target.viaConnectionID == nil)
    }
    @Test func retainedTransferFailurePreservesOnlyTypedDiagnosticsAndReadsLegacySnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SSHTransferStore(directory: root), id = UUID(), endpoints = [profile(), profile()]
        let operation = try store.operationLock(id)
        defer { withExtendedLifetime(operation) {} }
        let raw = qc_ssh_diagnostic(size: UInt32(MemoryLayout<qc_ssh_diagnostic>.size), endpoint_index: 2, hop_count: 1, phase: 5)
        let diagnostic = try #require(SSHDiagnostic(raw, endpoints: endpoints))
        let recorder = try SSHTransferRecorder(store: store, id: id, progressAvailable: true)
        recorder.fail(MCPFailure("failure", code: .accessDenied, details: .object(["ssh": diagnostic.value])))
        let stored = try store.loadStatus(id)
        let restored = try #require(stored)
        #expect(restored.state == .failed)
        #expect(restored.value["ssh_diagnostic"] == diagnostic.value)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        legacy.removeValue(forKey: "sshDiagnostic")
        let decoded = try JSONDecoder().decode(SSHTransferStatus.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.sshDiagnostic == nil)
        var invalid = try #require(diagnostic.value.objectValue)
        invalid["phase"] = "unexpected-secret"
        #expect(SSHDiagnostic(value: .object(invalid)) == nil)
        invalid["phase"] = "connect"; invalid["jump_count"] = .int(Int.max)
        #expect(SSHDiagnostic(value: .object(invalid)) == nil)
    }
    @Test func missingSavedCredentialIdentifiesItsHopBeforeTransportStarts() async throws {
        var jump = profile(); jump.storesCredential = true
        let target = profile()
        do {
            _ = try await SSHRouteRequest.make(profile: target, jumps: [profile(), jump], credentials: MissingDiagnosticCredentials(), timeoutMilliseconds: 1000, maximumOutputBytes: 1000)
            Issue.record("Expected missing jump credential")
        } catch let failure as MCPFailure {
            #expect(failure.code == .credentialUnavailable)
            let diagnostic = failure.details?.objectValue?["ssh"]?.objectValue
            #expect(diagnostic?["connection_id"] == .string(jump.id.uuidString))
            #expect(diagnostic?["endpoint_index"] == 2)
            #expect(diagnostic?["phase"] == "preparing")
        }
    }
    @Test func synchronousTransferAndUnknownTaskLaunchKeepTheirDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile()
        try SSHConnectionStore(directory: root).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true; policy.mode = .fullAccess
        policy.ssh = .init(connectionIDs: [profile.id], executionConnectionIDs: [profile.id], fileReadConnectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root, sshTransport: DiagnosticFailureTransport(profile: profile))
        do {
            _ = try await runtime.call("querycraft_ssh_upload_file", arguments: ["connection_id": .string(profile.id.uuidString), "local_path": "/fixture/source", "remote_path": "/fixture/target", "confirm_high_risk": true])
            Issue.record("Expected transfer failure")
        } catch let failure as MCPFailure {
            #expect(failure.details?.objectValue?["ssh"]?.objectValue?["phase"] == "host_key")
            #expect(failure.message.contains("transfer_id="))
        }
        let launch = try await runtime.call("querycraft_ssh_start_task", arguments: ["connection_id": .string(profile.id.uuidString), "command": "owned mock task", "confirm_high_risk": true])
        #expect(launch.objectValue?["state"] == "unknown")
        #expect(launch.objectValue?["error_code"] == .string(MCPFailureCode.timeout.rawValue))
        #expect(launch.objectValue?["ssh_diagnostic"]?.objectValue?["phase"] == "command")
        #expect(launch.objectValue?["automatic_retry"] == false)
        await runtime.shutdown()
    }
    @Test func malformedDiagnosticsAreIgnoredAndLegacyFailureShapeRemainsCompatible() throws {
        let endpoints = [profile()]
        var raw = qc_ssh_diagnostic(size: 0, endpoint_index: 1, hop_count: 0, phase: 5)
        #expect(SSHDiagnostic(raw, endpoints: endpoints) == nil)
        raw.size = UInt32(MemoryLayout<qc_ssh_diagnostic>.size); raw.endpoint_index = 2
        #expect(SSHDiagnostic(raw, endpoints: endpoints) == nil)
        raw.endpoint_index = 1; raw.phase = 7
        #expect(SSHDiagnostic(raw, endpoints: endpoints) == nil)
        raw.phase = 999
        #expect(SSHDiagnostic(raw, endpoints: endpoints) == nil)
        raw.phase = 5; raw.hop_count = 4
        #expect(SSHDiagnostic(raw, endpoints: endpoints) == nil)
        do { try SSHResult(status: Int32(QC_SSH_AUTH)).validate(); Issue.record("Expected auth failure") }
        catch let error as MCPFailure {
            #expect(error.code == .credentialUnavailable)
            #expect(error.value.objectValue?["error"]?.objectValue?["details"] == nil)
        }
    }
}

struct MCPRuntimeInfoTests {
    private func bundle(_ root: URL, _ name: String, id: String, runtime: String? = nil) throws -> URL {
        let url = root.appending(path: name), contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "3"]
        if let runtime { info["QCRuntimeBuild"] = runtime }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        return url
    }
    @Test func installedUpdatesDoNotReplaceCapturedLoadedIdentityOrCapabilities() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try bundle(root, "old.app", id: "io.github.future0923.QueryCraft.MCP.Dev", runtime: "old-build")
        let new = try bundle(root, "new.app", id: "io.github.future0923.QueryCraft.MCP.Dev", runtime: "new-build")
        let oldPlugin = try bundle(root, "old.bundle", id: "io.github.future0923.QueryCraft.SSH")
        let newPlugin = try bundle(root, "new.bundle", id: "io.github.future0923.QueryCraft.SSH")
        let hostLink = root.appending(path: "MCP/Current"), pluginLink = root.appending(path: "Plugins/SSH/Current")
        try FileManager.default.createDirectory(at: hostLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginLink, withIntermediateDirectories: true)
        let installedPlugin = pluginLink.appending(path: "QueryCraftSSH.bundle")
        try FileManager.default.createSymbolicLink(at: hostLink, withDestinationURL: old)
        try FileManager.default.createSymbolicLink(at: installedPlugin, withDestinationURL: oldPlugin)
        let runtime = MCPRuntimeInfo(directory: root, hostURL: URL(fileURLWithPath: old.path, isDirectory: true))
        let ssh = SSHPluginRuntimeInfo(bundle: .read(at: oldPlugin), files: true, management: true,
            pooling: true, progress: true, routes: false, diagnostics: false)
        #expect(runtime.value(ssh: ssh).objectValue?["reconnect_required"] == false)
        try FileManager.default.removeItem(at: hostLink)
        try FileManager.default.createSymbolicLink(at: hostLink, withDestinationURL: new)
        try FileManager.default.removeItem(at: installedPlugin)
        try FileManager.default.createSymbolicLink(at: installedPlugin, withDestinationURL: newPlugin)
        let value = runtime.value(ssh: ssh).objectValue
        #expect(value?["reconnect_required"] == true)
        #expect(value?["host"]?.objectValue?["loaded"]?.objectValue?["runtime_build"] == "old-build")
        #expect(value?["host"]?.objectValue?["installed"]?.objectValue?["runtime_build"] == "new-build")
        #expect(value?["ssh"]?.objectValue?["loaded"]?.objectValue?["extensions"]?.objectValue?["routes"] == .null)
        #expect(value?["ssh"]?.objectValue?["reconnect_required"] == true)
        let afterReconnect = MCPRuntimeInfo(directory: root, hostURL: new)
        let newSSH = SSHPluginRuntimeInfo(bundle: .read(at: newPlugin), files: true, management: true,
            pooling: true, progress: true, routes: true, diagnostics: true)
        #expect(afterReconnect.value(ssh: newSSH).objectValue?["reconnect_required"] == false)
        #expect(afterReconnect.value(ssh: nil).objectValue?["ssh"]?.objectValue?["reconnect_required"] == true)
    }
    @Test func discoveryAndAuthorizationIncludeLocalRuntimeInfoInEveryMode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPPolicyStore(directory: root), runtime = MCPRuntime(directory: root)
        var policy = MCPPolicy(); policy.enabled = true
        for mode in MCPToolDiscovery.allCases {
            policy.optimizations = .init(discovery: mode); try store.save(policy)
            #expect(try await runtime.tools().contains { $0.name == "querycraft_runtime_info" })
            let value = try await runtime.call("querycraft_runtime_info", arguments: [:])
            #expect(value.objectValue?["automatic_retry"] == false)
        }
        policy.disabledTools.insert("runtime_info"); try store.save(policy)
        #expect(try await !runtime.tools().contains { $0.name == "querycraft_runtime_info" })
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_runtime_info", arguments: [:]) }
        policy.disabledTools = []; policy.enabled = false; try store.save(policy)
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_runtime_info", arguments: [:]) }
        await runtime.shutdown()
    }
}

private struct MissingDiagnosticCredentials: CredentialStore {
    func password(for profileID: UUID) async throws -> String? { nil }
    func save(password: String, for profileID: UUID) async throws {}
    func delete(for profileID: UUID) async throws {}
}

private actor DiagnosticFailureTransport: SSHTransport {
    nonisolated let supportsFiles = true
    nonisolated let supportsFileManagement = true
    let commandDiagnostic: SSHDiagnostic
    let fileDiagnostic: SSHDiagnostic
    init(profile: SSHConnection) {
        commandDiagnostic = SSHDiagnostic(qc_ssh_diagnostic(size: UInt32(MemoryLayout<qc_ssh_diagnostic>.size), endpoint_index: 1, hop_count: 0, phase: 9), endpoints: [profile])!
        fileDiagnostic = SSHDiagnostic(qc_ssh_diagnostic(size: UInt32(MemoryLayout<qc_ssh_diagnostic>.size), endpoint_index: 1, hop_count: 0, phase: 5), endpoints: [profile])!
    }
    func execute(_ request: SSHRequest) async throws -> SSHResult {
        if request.command?.hasPrefix("test -x /bin/bash") == true { return .init(exitStatus: 0) }
        return .init(status: Int32(QC_SSH_TIMEOUT), commandMayHaveRun: true, diagnostic: commandDiagnostic)
    }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        .init(status: Int32(QC_SSH_HOST_KEY), diagnostic: fileDiagnostic)
    }
}
