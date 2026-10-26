import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor struct SSHActivityTests {
    private func profile() -> SSHConnection {
        .init(id: UUID(), name: "Activity fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/key", storesCredential: false)
    }
    @Test func snapshotsAreBoundToAccountAndKeepLocalRecordsWhenMCPDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), other = self.profile()
        try SSHConnectionStore(directory: root).insert(profile)
        try SSHConnectionStore(directory: root).insert(other)
        for owner in [profile, other] {
            try SSHTaskStore(directory: root).insert(.init(id: UUID(), connectionID: owner.id, binding: SSHTaskRecord.binding(owner), createdAt: Date()))
        }
        try MCPPolicyStore(directory: root).save(MCPPolicy())
        let service = SSHActivityService(directory: root, profile: profile, transport: ActivityTransport())
        let first = try await service.snapshot()
        #expect(first.tasks.count == 1 && first.tasks[0].matches(profile))
        #expect(first.allowedTools.isEmpty)
        await #expect(throws: MCPFailure.self) { _ = try await service.call("ssh_task_status", arguments: ["task_id": .string(first.tasks[0].id.uuidString)]) }
        var changed = profile; changed.host = "another-host"
        try SSHConnectionStore(directory: root).replace(changed, expecting: profile)
        await #expect(throws: MCPFailure.self) { _ = try await service.snapshot() }
        await service.close()
    }
    @Test(.timeLimit(.minutes(1))) func activeTransferCancellationReachesOwnerAndRetainsUnknownRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), transport = ActivityTransport()
        try SSHConnectionStore(directory: root).insert(profile)
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        let task = Task {
            try await runtime.call("querycraft_ssh_upload_file", arguments: ["connection_id": .string(profile.id.uuidString),
                "local_path": .string(root.appending(path: "source").path), "remote_path": "/destination", "confirm_high_risk": true])
        }
        await transport.waitForFile()
        let records = SSHTransferStore(directory: root)
        let record = try #require(records.load().first)
        #expect(record.cancellationVersion == 1)
        #expect(try records.isActive(record.id))
        let service = SSHActivityService(directory: root, profile: profile, transport: transport)
        let snapshot = try await service.snapshot()
        #expect(snapshot.transfers.first?.active == true)
        try await service.cancelTransfer(record.id)
        switch await task.result {
        case .success: Issue.record("Cancelled transfer unexpectedly completed")
        case .failure(let error): #expect(MCPFailure.normalized(error).code == .cancelled)
        }
        #expect(try !records.isActive(record.id))
        #expect(try records.load().count == 1)
        #expect(records.cancellationRequested(record.id))
        await #expect(throws: MCPFailure.self) { try await service.cancelTransfer(record.id) }
        try records.remove(record.id)
        #expect(!records.cancellationRequested(record.id))
        await service.close(); await runtime.shutdown()
    }
    @Test func legacyRecordsDoNotAdvertiseCancellationAndRevocationIsImmediate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), records = SSHTransferStore(directory: root), id = UUID()
        try SSHConnectionStore(directory: root).insert(profile)
        let path = root.appending(path: "target").path
        let legacy = SSHTransferRecord(id: id, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), upload: true,
            remotePath: "/target", localPath: path, stagingPath: SSHTransferRecord.stagingPath(destination: "/target", id: id), createdAt: Date())
        let encoded = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(SSHTransferRecord.self, from: encoded).cancellationVersion == nil)
        try records.insert(legacy)
        let lock = try records.operationLock(id); defer { withExtendedLifetime(lock) {} }
        #expect(throws: MCPFailure.self) { try records.requestCancellation(legacy) }
        var policy = MCPPolicy(); policy.enabled = true
        policy.ssh = .init(connectionIDs: [profile.id], fileTransferConnectionIDs: [profile.id])
        try MCPPolicyStore(directory: root).save(policy)
        let service = SSHActivityService(directory: root, profile: profile, transport: ActivityTransport())
        await #expect(throws: MCPFailure.self) { try await service.cancelTransfer(id) }
        #expect(!records.cancellationRequested(id))
        await service.close()
    }
    @Test func inspectionLockIsNotReportedAsAnActiveTransferOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), id = UUID(), records = SSHTransferStore(directory: root)
        try SSHConnectionStore(directory: root).insert(profile)
        try MCPPolicyStore(directory: root).save(MCPPolicy())
        let record = SSHTransferRecord(id: id, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), upload: true,
            remotePath: "/target", localPath: root.appending(path: "source").path,
            stagingPath: SSHTransferRecord.stagingPath(destination: "/target", id: id), createdAt: Date(), cancellationVersion: 1)
        try records.insert(record)
        let inspection = try records.operationLock(id); defer { withExtendedLifetime(inspection) {} }
        let service = SSHActivityService(directory: root, profile: profile, transport: ActivityTransport())
        #expect(try records.isActive(id))
        #expect(try !records.isActive(id, transferOwner: true))
        #expect(try await service.snapshot().transfers.first?.active == false)
        #expect(throws: MCPFailure.self) { try records.requestCancellation(record) }
        await service.close()
    }
    @Test(.timeLimit(.minutes(1))) func lateDetailResponseCannotReplaceNewSelection() async throws {
        let profile = profile(), service = ActivityFixtureService(), first = UUID(), second = UUID()
        await service.setBlocked(first)
        let model = SSHActivityModel(profile: profile, service: service)
        model.snapshot = SSHActivitySnapshot(allowedTools: MCPToolCatalog.sshTools)
        model.select(.task(first))
        let loading = Task { await model.refreshDetail() }
        await service.waitForStatus()
        #expect(model.detailLoading)
        model.select(.task(second))
        #expect(model.detail == nil && model.log.isEmpty)
        await model.refreshDetail()
        #expect(model.detail?.objectValue?["task_id"] == .string(second.uuidString))
        await service.releaseStatus()
        await loading.value
        #expect(model.detail?.objectValue?["task_id"] == .string(second.uuidString))
    }
    @Test func logByteWindowsReassembleUTF8AndResetBetweenStreams() async throws {
        let profile = profile(), service = ActivityFixtureService()
        let streamed = SSHActivityModel(profile: profile, service: service)
        streamed.snapshot = SSHActivitySnapshot(allowedTools: MCPToolCatalog.sshTools)
        streamed.select(.task(UUID()))
        await streamed.refreshDetail(); #expect(streamed.nextOffset == 2)
        await streamed.refreshDetail(); #expect(streamed.log == "雪" && streamed.nextOffset == 3)
        streamed.changeStream("stderr")
        await streamed.refreshDetail()
        #expect(streamed.log == "stderr" && streamed.nextOffset == 6)
        await service.setSnapshotFailure(true)
        await streamed.refreshList()
        #expect(streamed.snapshot != nil && streamed.listError != nil)
    }
    @Test func confirmationsPinSelectionAndRequireUnknownAcknowledgment() async throws {
        let profile = profile(), service = ActivityFixtureService()
        let active = SSHActivityModel(profile: profile, service: service)
        let first = UUID(), second = UUID()
        active.select(.task(first))
        let confirmation = SSHActivityConfirmation(action: .forgetTask, selection: .task(first), inspectionToken: nil)
        #expect(await active.perform(confirmation, acknowledged: false) == false)
        #expect(await service.writes == 0)
        active.select(.task(second))
        #expect(await active.perform(confirmation, acknowledged: true) == false)
        #expect(await service.writes == 0)
        active.select(.task(first))
        #expect(await active.perform(confirmation, acknowledged: true))
        #expect(await service.writes == 1)
    }
}

private actor ActivityTransport: SSHTransport {
    nonisolated let supportsFiles = true
    nonisolated let supportsFileManagement = true
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    func waitForFile() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func execute(_ request: SSHRequest) async throws -> SSHResult { .init(exitStatus: 0) }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult {
        started = true; waiter?.resume(); waiter = nil
        try await Task.sleep(for: .seconds(3600))
        return .init(exitStatus: 0)
    }
}

private actor ActivityFixtureService: SSHActivityServing {
    var blocked: UUID?
    var continuation: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    var snapshotFailure = false
    var writes = 0
    func setBlocked(_ id: UUID) { blocked = id }
    func setSnapshotFailure(_ value: Bool) { snapshotFailure = value }
    func waitForStatus() async { if continuation == nil { await withCheckedContinuation { waiter = $0 } } }
    func releaseStatus() { continuation?.resume(); continuation = nil }
    func snapshot() throws -> SSHActivitySnapshot {
        if snapshotFailure { throw MCPFailure("fixture failure") }
        return SSHActivitySnapshot()
    }
    func call(_ tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPJSONValue {
        if tool == "ssh_task_status" {
            if arguments["task_id"] == blocked.map({ .string($0.uuidString) }) {
                await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
            }
            return .object(["task_id": arguments["task_id"] ?? .null, "state": "running"])
        }
        if tool == "ssh_task_output" {
            let offset = arguments["offset"]?.intValue ?? 0
            let bytes: Data
            if arguments["stream"] == "stderr" { bytes = Data("stderr".utf8) }
            else { bytes = offset == 0 ? Data([0xe9, 0x9b]) : (offset == 2 ? Data([0xaa]) : Data()) }
            return .object(["content_base64": .string(bytes.base64EncodedString()), "next_offset": .int(offset + bytes.count), "final": false])
        }
        writes += 1; return .object([:])
    }
    func cancelTransfer(_ id: UUID) { writes += 1 }
    func close() {}
}
