import Foundation
import CryptoKit
import Darwin

extension MCPRuntime {
    func callSSHRecovery(_ tool: String, args: [String: MCPJSONValue], profile: SSHConnection) async throws -> MCPJSONValue {
        guard sshPermitted(profile, tool: tool, policy: try store.load()) else { throw MCPFailure("This account is not authorized for transfer recovery.", code: .accessDenied) }
        let records = SSHTransferStore(directory: store.url.deletingLastPathComponent())
        if tool == "ssh_list_transfers" {
            let offset = args.integer("offset", default: 0), maximum = args.integer("max_records", default: 20)
            guard (0...512).contains(offset), (1...100).contains(maximum) else { throw MCPFailure("Invalid transfer record window.") }
            let all = try records.load().filter { record in
                guard record.matches(profile) else { return false }
                if args.flag("include_completed") { return true }
                return try records.loadStatus(record.id)?.state != .completed
            }.sorted { a, b in
                a.createdAt == b.createdAt ? a.id.uuidString < b.id.uuidString : a.createdAt > b.createdAt
            }
            let budget = max(0, try store.load().maximumResultBytes - 512)
            var values: [MCPJSONValue] = []
            for record in all.dropFirst(offset).prefix(maximum) {
                let candidate = values + [try records.statusValue(record)]
                guard try JSONEncoder().encode(MCPJSONValue.array(candidate)).count <= budget else {
                    if values.isEmpty { throw MCPFailure("Increase the result budget to fit a transfer record.", code: .resultTooLarge) }
                    break
                }
                values = candidate
            }
            let next = offset + values.count
            return .object(["transfers": .array(values), "total_records": .int(all.count),
                "next_offset": next < all.count ? .int(next) : .null, "automatic_retry": false])
        }
        guard let id = UUID(uuidString: try args.requiredString("transfer_id")),
              let record = try records.load().first(where: { $0.id == id && $0.matches(profile) }) else { throw MCPFailure("Transfer not found for this exact account.", code: .connectionNotFound) }
        let lock = try records.operationLock(id); defer { withExtendedLifetime(lock) {} }
        let timeout = args.integer("timeout_seconds", default: 30)
        let snapshot = try await transferSnapshot(record, profile: profile, tool: tool, timeout: timeout)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let token = SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
        if tool == "ssh_inspect_transfer" {
            return .object(["transfer": record.value, "metadata": snapshot, "inspection_token": .string(token),
                "destination_outcome": "unknown; metadata is not a content verification", "automatic_retry": false])
        }
        guard args.flag("confirm_high_risk"), args.flag("acknowledge_outcome_unknown") else {
            throw MCPFailure("Review both exact paths, acknowledge the unknown destination outcome and confirm cleanup.", code: .confirmationRequired)
        }
        guard sshTransport?.supportsFileManagement == true else { throw MCPFailure("Upgrade the SSH plugin to 0.3.0 for tracked cleanup.", code: .unsupported) }
        guard try args.requiredString("inspection_token") == token else { throw MCPFailure("Transfer metadata changed. Inspect it again before cleanup.") }
        guard sshPermitted(profile, tool: tool, policy: try store.load()),
              try sshConnections.load().contains(profile) else { throw MCPFailure("SSH authorization changed.", code: .accessDenied) }
        let staging = snapshot.objectValue?["staging"]?.objectValue
        if staging?["exists"] == true {
            guard staging?["type"] == "file" else { throw MCPFailure("Cleanup refuses symlinks, directories and special files.") }
            if record.upload {
                let request = SSHFileRequest(operation: .unlink, remotePath: record.stagingPath)
                _ = try await performSSH(profile, tool: tool, file: request, timeout: timeout)
            } else {
                guard Darwin.unlink(record.stagingPath) == 0 else { throw MCPFailure("Cannot unlink the tracked local staging file. Destination was not modified.", code: .driverFailure) }
            }
        }
        try records.remove(id)
        return .object(["transfer_id": .string(id.uuidString), "local_record_removed": true, "staging_removed_or_absent": true,
            "destination_modified_by_cleanup": false, "destination_outcome": "not_verified", "automatic_retry": false])
    }

    private func transferSnapshot(_ record: SSHTransferRecord, profile: SSHConnection, tool: String, timeout: Int) async throws -> MCPJSONValue {
        func local(_ path: String) throws -> MCPJSONValue {
            var attributes = stat()
            if Darwin.lstat(path, &attributes) != 0 {
                if errno == ENOENT { return .object(["exists": false]) }
                throw MCPFailure("Cannot inspect the tracked local path.", code: .driverFailure)
            }
            let type: String = switch attributes.st_mode & S_IFMT { case S_IFREG: "file"; case S_IFDIR: "directory"; case S_IFLNK: "symlink"; default: "other" }
            return .object(["exists": true, "type": .string(type), "size_bytes": .int(Int(attributes.st_size)),
                "modified_seconds": .int(Int(attributes.st_mtimespec.tv_sec)), "modified_nanoseconds": .int(Int(attributes.st_mtimespec.tv_nsec)),
                "inode": .string(String(attributes.st_ino)), "device": .int(Int(attributes.st_dev))])
        }
        func remote(_ path: String) async throws -> MCPJSONValue {
            let request = SSHFileRequest(operation: .stat, remotePath: path)
            do {
                let result = try await performSSH(profile, tool: tool, file: request, timeout: timeout)
                var attributes = try request.result(result).objectValue ?? [:]; attributes["exists"] = true
                return .object(attributes)
            } catch let error as MCPFailure where error.code == .invalidArgument && error.message == "Remote file or directory was not found." {
                return .object(["exists": false])
            }
        }
        let staging: MCPJSONValue, destination: MCPJSONValue
        if record.upload { staging = try await remote(record.stagingPath); destination = try await remote(record.remotePath) }
        else { staging = try local(record.stagingPath); destination = try local(record.localPath) }
        return .object(["transfer_id": .string(record.id.uuidString), "account_binding": .string(record.binding),
            "staging_path": .string(record.stagingPath), "destination_path": .string(record.upload ? record.remotePath : record.localPath),
            "staging": staging, "destination": destination])
    }
}
