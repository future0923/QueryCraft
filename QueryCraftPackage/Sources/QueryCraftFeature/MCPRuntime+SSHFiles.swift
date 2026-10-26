import Foundation

extension MCPRuntime {
    func callSSHFile(_ tool: String, args: [String: MCPJSONValue], profile: SSHConnection, background: Bool = false) async throws -> MCPJSONValue {
        guard sshTransport?.supportsFiles == true else { throw MCPFailure("Install SSH 0.2.0 or later and reconnect for SFTP tools.", code: .unsupported) }
        let management = MCPToolCatalog.sshFileWrites.contains(tool)
        if management && sshTransport?.supportsFileManagement != true { throw MCPFailure("Upgrade SSH to 0.3.0 and reconnect for file management.", code: .unsupported) }
        guard sshPermitted(profile, tool: tool, policy: try store.load()) else { throw MCPFailure("This file operation is not authorized.", code: .accessDenied) }
        let operation: SSHFileRequest.Operation = switch tool {
        case "ssh_stat_file": .stat
        case "ssh_list_files": .list
        case "ssh_read_file": .read
        case "ssh_upload_file": .upload
        case "ssh_create_directory": .mkdir
        case "ssh_move_path": .move
        case "ssh_remove_path": args.string("kind") == "empty_directory" ? .rmdir : .unlink
        default: .download
        }
        let transferring = MCPToolCatalog.sshTransfers.contains(tool)
        if (transferring || management) && !args.flag("confirm_high_risk") {
            throw MCPFailure("Confirm the exact local and remote paths and any overwrite before setting confirm_high_risk=true.", code: .confirmationRequired)
        }
        var file = SSHFileRequest(operation: operation, remotePath: try args.requiredString(transferring ? "remote_path" : "path"))
        file.offset = args.integer("offset", default: 0)
        file.maximumEntries = args.integer("max_entries", default: 100)
        file.maximumTransferBytes = args.integer("max_transfer_bytes", default: 67_108_864)
        file.overwrite = args.flag("overwrite")
        if transferring { file.localPath = try args.requiredString("local_path") }
        if operation == .list && file.offset > 100_000 { throw MCPFailure("Directory offset exceeds the scan limit. Narrow the directory.") }
        let recordID = UUID()
        var record: SSHTransferRecord?
        let records = SSHTransferStore(directory: store.url.deletingLastPathComponent())
        if operation == .move { file.temporaryPath = try args.requiredString("destination_path") }
        if transferring && sshTransport?.supportsFileManagement == true, let local = file.localPath {
            let staging = SSHTransferRecord.stagingPath(destination: operation == .upload ? file.remotePath : local, id: recordID)
            file.temporaryPath = staging
            record = SSHTransferRecord(id: recordID, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), upload: operation == .upload,
                remotePath: file.remotePath, localPath: local, stagingPath: staging, createdAt: Date(), cancellationVersion: 1)
        } else if operation == .upload {
            file.temporaryPath = SSHTransferRecord.stagingPath(destination: file.remotePath, id: recordID)
        }
        try file.validate()
        guard (1...300).contains(args.integer("timeout_seconds", default: 30)) else { throw MCPFailure("Invalid transfer timeout.") }
        if background {
            guard record != nil else { throw MCPFailure("Install SSH 0.3.0 or later for tracked transfers.", code: .unsupported) }
            let policy = try store.load()
            guard !stopped, sshTransfers.count < min(8, policy.maximumSessions) else { throw MCPFailure("Background transfer capacity reached.", code: .capacity) }
        }
        let ownership = try record.map { try TransferOwnership(store: records, record: $0) }
        let recorder = try record.map { try SSHTransferRecorder(store: records, id: $0.id, progressAvailable: sshTransport?.supportsTransferProgress == true) }
        if let recorder { file.progress = { recorder.receive($0) } }
        if background, let record {
            let request = file
            let task = Task {
                defer { self.sshTransfers.removeValue(forKey: record.id) }
                _ = try? await self.runSSHFile(tool, args: args, profile: profile, file: request, record: record,
                    ownership: ownership, recorder: recorder, background: true)
            }
            sshTransfers[record.id] = task
            return .object(["transfer_id": .string(record.id.uuidString), "state": "accepted",
                "progress_available": .bool(sshTransport?.supportsTransferProgress == true),
                "next_step": "Query ssh_transfer_status. This transfer runs only while its owning MCP process lives; never retry automatically.", "automatic_retry": false])
        }
        return try await runSSHFile(tool, args: args, profile: profile, file: file, record: record,
            ownership: ownership, recorder: recorder, background: false)
    }

    // Both advisory lock objects are immutable after acquisition; this wrapper
    // only transfers their ownership/lifetime, never accesses their descriptors.
    final class TransferOwnership: @unchecked Sendable {
        private let operation: MCPComponentLock
        private let owner: MCPComponentLock
        init(store: SSHTransferStore, record: SSHTransferRecord) throws {
            operation = try store.operationLock(record.id); owner = try store.ownerLock(record.id)
            try store.insert(record)
        }
    }
    private func runSSHFile(_ tool: String, args: [String: MCPJSONValue], profile: SSHConnection, file: SSHFileRequest,
                            record: SSHTransferRecord?, ownership: TransferOwnership?, recorder: SSHTransferRecorder?, background: Bool) async throws -> MCPJSONValue {
        defer { withExtendedLifetime(ownership) {} }
        let records = SSHTransferStore(directory: store.url.deletingLastPathComponent())
        do {
            let result: SSHResult
            let timeout = args.integer("timeout_seconds", default: 30)
            let output = file.operation == .read ? args.integer("max_bytes", default: 16_384) : 65_536
            if let record {
                result = try await withThrowingTaskGroup(of: SSHResult.self) { group in
                    group.addTask { try await self.performSSH(profile, tool: tool, file: file, timeout: timeout, output: output,
                        additionalTool: background ? "ssh_start_transfer" : nil) }
                    group.addTask {
                        while true {
                            try Task.checkCancellation()
                            if records.cancellationRequested(record.id) { throw CancellationError() }
                            recorder?.heartbeat()
                            try await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    defer { group.cancelAll() }
                    guard let value = try await group.next() else { throw CancellationError() }
                    return value
                }
            } else {
                result = try await performSSH(profile, tool: tool, file: file, timeout: timeout, output: output)
            }
            var value = try file.result(result, encoding: args.string("encoding") ?? "utf8")
            if let record {
                do { try recorder?.finish(result: value) }
                catch { throw MCPFailure("Transfer returned success but its final result could not be persisted. Inspect the destination before repeating it.", code: .outcomeUnknown) }
                var fields = value.objectValue ?? [:]; fields["transfer_id"] = .string(record.id.uuidString); value = .object(fields)
            }
            return value
        } catch {
            if let record {
                let failure = MCPFailure.normalized(error)
                recorder?.fail(failure)
                throw MCPFailure(failure.message + " Inspect transfer_id=" + record.id.uuidString + " with ssh_transfer_status/ssh_inspect_transfer before cleanup or repetition.", code: failure.code, details: failure.details)
            }
            throw error
        }
    }
}
