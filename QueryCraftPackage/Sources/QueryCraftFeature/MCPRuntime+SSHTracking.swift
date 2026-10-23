import Foundation

extension MCPRuntime {
    func callSSHTracking(_ tool: String, args: [String: MCPJSONValue], profile: SSHConnection) async throws -> MCPJSONValue {
        guard sshTransport?.supportsFiles == true, sshTransport?.supportsFileManagement == true else {
            throw MCPFailure("Install SSH 0.3.0 or later and reconnect for tracked transfers.", code: .unsupported)
        }
        guard sshPermitted(profile, tool: tool, policy: try store.load()) else {
            throw MCPFailure("This transfer operation is not authorized.", code: .accessDenied)
        }
        if tool == "ssh_start_transfer" {
            let direction = try args.requiredString("direction")
            guard ["upload", "download"].contains(direction) else { throw MCPFailure("Choose upload or download.") }
            return try await callSSHFile(direction == "upload" ? "ssh_upload_file" : "ssh_download_file", args: args, profile: profile, background: true)
        }
        let records = SSHTransferStore(directory: store.url.deletingLastPathComponent())
        guard let id = UUID(uuidString: try args.requiredString("transfer_id")),
              let record = try records.load().first(where: { $0.id == id && $0.matches(profile) }) else {
            throw MCPFailure("Transfer not found for this exact account.", code: .connectionNotFound)
        }
        if tool == "ssh_transfer_status" { return try records.statusValue(record) }
        guard args.flag("confirm_high_risk") else { throw MCPFailure("Confirm the exact transfer before this operation.", code: .confirmationRequired) }
        if tool == "ssh_cancel_transfer" {
            guard try !records.status(record).terminal else { throw MCPFailure("Transfer is already terminal. Query its result.") }
            try records.requestCancellation(record)
            return .object(["transfer_id": .string(id.uuidString), "cancellation_requested": true, "next_step": "Poll ssh_transfer_status for the actual outcome.", "automatic_retry": false])
        }
        let lock = try records.operationLock(id); defer { withExtendedLifetime(lock) {} }
        guard try records.status(record).state == .completed else {
            throw MCPFailure("Only completed result records can be forgotten. Inspect and clean up failed/unknown transfers instead.")
        }
        try records.remove(id)
        return .object(["transfer_id": .string(id.uuidString), "local_record_removed": true, "destination_modified": false])
    }
}
