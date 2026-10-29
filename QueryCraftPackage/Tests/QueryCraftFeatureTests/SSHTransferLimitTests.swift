import Foundation
import Testing
import CQueryCraftSSHPluginAPI
@testable import QueryCraftFeature

@Suite(.timeLimit(.minutes(1)))
struct SSHTransferLimitTests {
    private func setup(status: Int32 = 0) throws -> (URL, SSHConnection, MCPRuntime, LimitTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: "qc-transfer-limit-" + UUID().uuidString)
        let profile = SSHConnection(id: UUID(), name: "limit fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/key", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], fileReadConnectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let transport = LimitTransport(status: status)
        return (root, profile, MCPRuntime(directory: root, sshTransport: transport), transport)
    }
    private func source(_ root: URL, bytes: Int) throws -> String {
        let url = root.appending(path: "source.jar")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
        return url.path
    }
    private func args(_ profile: SSHConnection, path: String) -> [String: MCPJSONValue] {
        ["connection_id": .string(profile.id.uuidString), "local_path": .string(path), "remote_path": "/fixture/remote",
         "direction": "upload", "confirm_high_risk": true]
    }
    private func call(_ runtime: MCPRuntime, tool: String, arguments: [String: MCPJSONValue], indirect: Bool) async throws -> MCPJSONValue {
        var arguments = arguments
        if tool != "ssh_start_transfer" { arguments.removeValue(forKey: "direction") }
        if indirect {
            return try await runtime.call("querycraft_plugin_call", arguments: ["plugin_id": "ssh", "tool": .string(tool), "arguments": .object(arguments)])
        }
        return try await runtime.call("querycraft_" + tool, arguments: arguments)
    }

    @Test(arguments: ["ssh_upload_file", "ssh_start_transfer"], [false, true])
    func oversizedAuthPackageFailsBeforeTransportOrRecoveryRecord(tool: String, indirect: Bool) async throws {
        let (root, profile, runtime, transport) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try source(root, bytes: 221_054_869)
        do {
            _ = try await call(runtime, tool: tool, arguments: args(profile, path: path), indirect: indirect)
            Issue.record("Oversized source must fail")
        } catch let failure as MCPFailure {
            let error = try #require(failure.value.objectValue?["error"]?.objectValue)
            #expect(failure.code == .capacity)
            #expect(failure.message.contains("221054869"))
            #expect(failure.message.contains("67108864"))
            #expect(error["details"]?.objectValue?["size_bytes"] == 221_054_869)
            #expect(error["details"]?.objectValue?["max_transfer_bytes"] == 67_108_864)
            #expect(error["details"]?.objectValue?["destination_outcome"] == "not_started")
            #expect(error["automatic_retry"] == false)
            #expect(error["recovery"]?.stringValue?.contains("max_transfer_bytes") == true)
            #expect(error["recovery"]?.stringValue?.contains("Close unused sessions") == false)
        }
        #expect(await transport.files.isEmpty)
        #expect(try SSHTransferStore(directory: root).load().isEmpty)
        await runtime.shutdown()
    }

    @Test(arguments: ["ssh_upload_file", "ssh_start_transfer"], [false, true])
    func explicitLargerLimitReachesTransport(tool: String, indirect: Bool) async throws {
        let (root, profile, runtime, transport) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try source(root, bytes: 221_054_869)
        var arguments = args(profile, path: path); arguments["max_transfer_bytes"] = 268_435_456
        if tool != "ssh_start_transfer" { await transport.release() }
        let result = try await call(runtime, tool: tool, arguments: arguments, indirect: indirect)
        if tool == "ssh_start_transfer" {
            let id = try #require(result.objectValue?["transfer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let task = try #require(await runtime.sshTransfers[id])
            await transport.release()
            await task.value
        } else { #expect(result.objectValue?["status"] == "completed") }
        #expect(await transport.files.count == 1)
        #expect(await transport.files.first?.maximumTransferBytes == 268_435_456)
        await runtime.shutdown()
    }

    @Test(arguments: [0, 64, 65, 1_073_741_825])
    func exactBoundaryAndHardMaximumHaveAccurateGuidance(bytes: Int) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var request = SSHFileRequest(operation: .upload, remotePath: "/fixture/remote")
        request.localPath = try source(root, bytes: bytes)
        request.maximumTransferBytes = 64
        if bytes <= 64 { try request.validateUploadSize() }
        else {
            do { try request.validateUploadSize(); Issue.record("Expected size rejection") }
            catch let failure as MCPFailure {
                #expect(failure.details?.objectValue?["size_bytes"] == .int(bytes))
                #expect(failure.details?.objectValue?["max_transfer_bytes"] == 64)
                if bytes > SSHFileRequest.supportedMaximumTransferBytes {
                    #expect(failure.recovery?.contains("another authorized transfer method") == true)
                }
            }
        }
    }

    @Test(arguments: ["ssh_download_file", "ssh_start_transfer"], [false, true])
    func driverLimitKeepsContextAndRecoveryAcrossReaderRestart(tool: String, indirect: Bool) async throws {
        let (root, profile, runtime, transport) = try setup(status: Int32(QC_SSH_LIMIT))
        defer { try? FileManager.default.removeItem(at: root) }
        var arguments = args(profile, path: root.appending(path: "download.jar").path)
        arguments["direction"] = "download"; arguments["max_transfer_bytes"] = 128
        if tool == "ssh_start_transfer" {
            let accepted = try await call(runtime, tool: tool, arguments: arguments, indirect: indirect)
            let id = try #require(accepted.objectValue?["transfer_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            let task = try #require(await runtime.sshTransfers[id])
            await transport.release(); await task.value
        } else {
            await transport.release()
            do { _ = try await call(runtime, tool: tool, arguments: arguments, indirect: indirect); Issue.record("Expected native limit") }
            catch let failure as MCPFailure {
                #expect(failure.details?.objectValue?["max_transfer_bytes"] == 128)
                #expect(failure.recovery?.contains("Inspect the transfer") == true)
                #expect(failure.recovery?.contains("max_transfer_bytes") == true)
            }
        }
        #expect(await transport.files.count == 1)
        await runtime.shutdown()
        let records = SSHTransferStore(directory: root)
        let record = try #require(records.load().first)
        let status = try records.statusValue(record).objectValue
        #expect(status?["state"] == "failed")
        #expect(status?["error_code"] == "CAPACITY_EXCEEDED")
        let error = try #require(status?["error"]?.objectValue)
        #expect(error["details"]?.objectValue?["reason"] == "transfer_byte_limit")
        #expect(error["details"]?.objectValue?["size_bytes"] == .null)
        #expect(error["details"]?.objectValue?["max_transfer_bytes"] == 128)
        #expect(error["automatic_retry"] == false)
        #expect(error["recovery"]?.stringValue?.contains("max_transfer_bytes") == true)
    }

    @Test func authorizationPrecedesLocalSizeDisclosure() async throws {
        let (root, profile, runtime, transport) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try source(root, bytes: 221_054_869)
        let store = MCPPolicyStore(directory: root)
        var policy = try store.load(); policy.ssh?.fileTransferConnectionIDs = []; try store.save(policy)
        do {
            _ = try await call(runtime, tool: "ssh_upload_file", arguments: args(profile, path: path), indirect: false)
            Issue.record("Expected authorization failure")
        } catch let failure as MCPFailure {
            #expect(failure.code == .accessDenied)
            #expect(failure.details?.objectValue?["size_bytes"] == nil)
        }
        #expect(await transport.files.isEmpty)
        await runtime.shutdown()
    }

    @Test func metadataPreflightDoesNotFollowFinalSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try source(root, bytes: 221_054_869)
        let link = root.appending(path: "symlink.jar").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        var request = SSHFileRequest(operation: .upload, remotePath: "/fixture/remote")
        request.localPath = link
        // Non-regular sources remain subject to the plugin's descriptor checks.
        try request.validateUploadSize()
    }

    @Test func oldStatusAndOrdinaryCapacityRecoveryRemainCompatible() throws {
        let old = SSHTransferStatus(progressAvailable: false)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "error")
        let decoded = try JSONDecoder().decode(SSHTransferStatus.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.error == nil)
        let capacity = MCPFailure("Connection capacity reached.", code: .capacity)
        #expect(capacity.value.objectValue?["error"]?.objectValue?["recovery"] == .string(MCPFailureCode.capacity.recovery))
    }
}

private actor LimitTransport: SSHTransport {
    nonisolated let supportsFiles = true
    nonisolated let supportsFileManagement = true
    let status: Int32
    var files: [SSHFileRequest] = []
    private let gate: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init(status: Int32) { self.status = status; (gate, continuation) = AsyncStream.makeStream() }
    func release() { continuation.finish() }
    func execute(_ request: SSHRequest) async throws -> SSHResult { throw MCPFailure("Unexpected command") }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        files.append(file)
        for await _ in gate {}
        try Task.checkCancellation()
        return SSHResult(status: status, stdout: Data(String(repeating: "a", count: 64).utf8))
    }
}
