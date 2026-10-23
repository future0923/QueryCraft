import Foundation

extension MCPRuntime {
    func callSSHTask(_ tool: String, args: [String: MCPJSONValue], profile: SSHConnection) async throws -> MCPJSONValue {
        let policy = try store.load()
        guard sshPermitted(profile, tool: tool, policy: policy) else { throw MCPFailure("This task operation requires the connection's explicit execution grant; writes also require full access.", code: .accessDenied) }
        let records = SSHTaskStore(directory: store.url.deletingLastPathComponent())
        if tool == "ssh_list_tasks" {
            return .array(try records.load().filter { $0.matches(profile) }.sorted { $0.createdAt > $1.createdAt }.map(\.value))
        }
        if MCPToolCatalog.sshTaskWrites.contains(tool) && !args.flag("confirm_high_risk") {
            throw MCPFailure("Confirm the exact task action or command before setting confirm_high_risk=true.", code: .confirmationRequired)
        }
        let action: String
        let id: UUID
        var payload: [String: MCPJSONValue] = [:]
        if tool == "ssh_start_task" {
            action = "start"; id = UUID()
            let command = try args.requiredString("command")
            let lifetime = args.integer("task_timeout_seconds", default: 3600), logs = args.integer("max_log_bytes", default: 4_194_304)
            let working = args.string("working_directory")
            guard !command.isEmpty, !command.contains("\0"), command.utf8.count <= 16_384,
                  (1...86400).contains(lifetime), (1024...67_108_864).contains(logs),
                  working.map({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }) ?? true else { throw MCPFailure("Invalid task command, directory or limits.") }
            payload = ["command": .string(command), "task_timeout_seconds": .int(lifetime), "max_log_bytes": .int(logs)]
            if let working { payload["working_directory"] = .string(working) }
        } else {
            guard let uuid = UUID(uuidString: try args.requiredString("task_id")),
                  try records.load().contains(where: { $0.id == uuid && $0.matches(profile) }) else { throw MCPFailure("Task not found for this exact SSH account.", code: .connectionNotFound) }
            id = uuid
            action = switch tool { case "ssh_task_status": "status"; case "ssh_task_output": "output"; case "ssh_cancel_task": "cancel"; default: "remove" }
        }
        let taskLock = try MCPComponentLock(directory: records.directory.appending(path: "SSHTaskOperations/" + id.uuidString))
        defer { withExtendedLifetime(taskLock) {} }
        if tool == "ssh_forget_task" {
            guard args.flag("acknowledge_task_may_be_running") else { throw MCPFailure("Acknowledge that the task may still be running; forgetting never terminates it.", code: .confirmationRequired) }
            try records.remove(id)
            return .object(["task_id": .string(id.uuidString), "local_record_removed": true, "remote_task_stopped": false, "remote_files_removed": false, "automatic_retry": false])
        }
        if action == "output" {
            let stream = args.string("stream") ?? "stdout", offset = args.integer("offset", default: 0), requested = args.integer("max_bytes", default: 16_384)
            guard ["stdout", "stderr"].contains(stream), (0...9_007_199_254_740_991).contains(offset), (1...262_144).contains(requested) else { throw MCPFailure("Invalid task log window.") }
            // Base64 from the server plus display text added below, including worst-case JSON escaping.
            let budget = max(0, (policy.maximumResultBytes - 2048) / 12)
            guard budget >= 1 else { throw MCPFailure("Increase the MCP result budget to read task output.", code: .resultTooLarge) }
            payload = ["stream": .string(stream), "offset": .int(offset), "max_bytes": .int(min(requested, budget))]
        }
        let command = try SSHTaskCommand.make(action: action, id: id, payload: payload)
        if action == "start" {
            let probe = try await performSSH(profile, tool: tool,
                command: "test -x /bin/bash && /bin/bash -c 'for t in nohup base64 dd wc tr mkdir rmdir mv rm chmod ls cat grep date sleep mkfifo; do command -v \"$t\" >/dev/null || exit 1; done'",
                timeout: args.integer("timeout_seconds", default: 30), output: 1024)
            guard probe.exitStatus == 0 else {
                throw MCPFailure("The server lacks an existing /bin/bash or a required standard system utility for background tasks. Nothing was installed. Ordinary SSH commands and SFTP remain available.", code: .unsupported)
            }
        }
        // Persist first: if the channel drops after launch, the task remains discoverable.
        if action == "start" { try records.insert(.init(id: id, connectionID: profile.id, binding: SSHTaskRecord.binding(profile), createdAt: Date())) }
        let result: SSHResult
        do {
            result = try await performSSH(profile, tool: tool, command: command, timeout: args.integer("timeout_seconds", default: 30), output: 1_048_576)
        } catch {
            if action == "start" {
                let failure = MCPFailure.normalized(error)
                return .object(["task_id": .string(id.uuidString), "state": "unknown", "automatic_retry": false,
                    "error_code": .string(failure.code.rawValue),
                    "ssh_diagnostic": failure.details?.objectValue?["ssh"].flatMap(SSHDiagnostic.init(value:))?.value ?? .null,
                    "message": "Launch outcome is unknown. Inspect this task ID before any new launch."])
            }
            throw error
        }
        guard !result.truncated, let decoded = try? JSONDecoder().decode(MCPJSONValue.self, from: result.stdout), var value = decoded.objectValue else {
            if action == "start" {
                return .object(["task_id": .string(id.uuidString), "state": "unknown", "automatic_retry": false,
                    "message": "No complete supervisor response. Inspect the task; do not relaunch automatically."])
            }
            throw MCPFailure("No complete supervisor response. Command outcome is unknown.", code: .outcomeUnknown)
        }
        if result.exitStatus != 0 || value["error"] != nil {
            if action == "start" {
                value["task_id"] = .string(id.uuidString); value["state"] = "unknown"; value["automatic_retry"] = false
                return .object(value)
            }
            throw MCPFailure(value["error"]?.stringValue ?? "SSH task operation failed.", code: .driverFailure)
        }
        if action == "output", let encoded = value["content_base64"]?.stringValue, let data = Data(base64Encoded: encoded) {
            value["display_text"] = .string(String(decoding: data, as: UTF8.self))
        }
        if action == "remove" { try records.remove(id) }
        return .object(value)
    }
}
