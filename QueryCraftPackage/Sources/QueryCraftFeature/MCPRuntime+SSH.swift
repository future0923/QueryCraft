import Foundation

extension MCPRuntime {
    struct SSHReuseConfiguration: Equatable {
        let profiles: [SSHConnection]
        let enabled: Bool
        let grants: MCPSSHPolicy?
        let disabledTools: Set<String>
    }
    /// Serialize invalidation across actor reentrancy. A caller cannot check
    /// out a cached session while another caller is still retiring its policy.
    func reconcileSSHConnections() async {
        guard let sshTransport else { return }
        while true {
            if let retirement = sshPoolRetirement {
                await retirement.task.value
                if sshPoolRetirement?.id == retirement.id { sshPoolRetirement = nil }
                continue
            }
            let policy = try? store.load(), profiles = try? sshConnections.load()
            let configuration = policy.flatMap { policy in profiles.map {
                SSHReuseConfiguration(profiles: $0.sorted { $0.id.uuidString < $1.id.uuidString }, enabled: policy.enabled,
                    grants: policy.ssh, disabledTools: policy.disabledTools)
            } }
            guard configuration != sshReuseConfiguration else { return }
            sshReuseConfiguration = configuration
            if let policy, let profiles {
                for operation in sshOperations.values where !sshOperationPermitted(operation, policy: policy, profiles: profiles) {
                    operation.task.cancel()
                }
            }
            let retirement = Task { await sshTransport.invalidate(connectionID: nil) }
            sshPoolRetirement = (UUID(), retirement)
        }
    }
    struct SSHOperation: Sendable {
        let profile: SSHConnection
        let tool: String
        let task: Task<SSHResult, any Error>
        var additionalTool: String? = nil
        var jumps: [SSHConnection] = []
    }

    var availableSSHTools: Set<String> {
        guard let sshTransport else { return [] }
        var available = MCPToolCatalog.sshTools
        if !sshTransport.supportsFiles || !sshTransport.supportsFileManagement { available.subtract(MCPToolCatalog.sshTrackingTools) }
        if !sshTransport.supportsFiles { available.subtract(MCPToolCatalog.sshFileReads.union(MCPToolCatalog.sshTransfers).union(MCPToolCatalog.sshRecoveryReads).union(MCPToolCatalog.sshRecoveryWrites)) }
        if !sshTransport.supportsFileManagement { available.subtract(MCPToolCatalog.sshFileWrites.union(MCPToolCatalog.sshRecoveryWrites)) }
        return available
    }
    func permittedSSHRoute(_ profile: SSHConnection, policy: MCPPolicy, profiles: [SSHConnection]) throws -> [SSHConnection] {
        let jumps = try SSHConnectionStore.route(to: profile, in: profiles)
        guard jumps.allSatisfy({ policy.ssh?.connectionIDs.contains($0.id) == true && !mutatingSSHConnections.contains($0.id) }) else {
            throw MCPFailure("Each saved SSH jump host requires its own explicit connection grant.", code: .accessDenied,
                details: .object(["required_grants": .array(["connection"]),
                    "missing_grants": .array(["connection"]),
                    "reason": "jump_host_not_authorized"]))
        }
        if !jumps.isEmpty || profile.authenticationMethod == .agent {
            guard sshTransport?.supportsRoutes == true else { throw MCPFailure("Install SSH 0.6.0 or later and reconnect for agent/jump-host connections.", code: .unsupported) }
        }
        return jumps
    }
    func sshOperationPermitted(_ operation: SSHOperation, policy: MCPPolicy, profiles: [SSHConnection]) -> Bool {
        guard sshPermitted(operation.profile, tool: operation.tool, policy: policy), profiles.contains(operation.profile),
              operation.additionalTool.map({ sshPermitted(operation.profile, tool: $0, policy: policy) }) ?? true,
              let jumps = try? permittedSSHRoute(operation.profile, policy: policy, profiles: profiles) else { return false }
        return jumps == operation.jumps
    }
    func sshPermitted(_ profile: SSHConnection, tool: String, policy: MCPPolicy) -> Bool {
        policy.enabled && !policy.disabledTools.contains(tool)
            && MCPSSHGrant.required(for: tool).allSatisfy { $0.permits(profile.id, policy: policy) }
    }

    func callSSH(_ tool: String, args: [String: MCPJSONValue], policy: MCPPolicy) async throws -> MCPJSONValue {
        guard sshTransport != nil else { throw MCPFailure("Install a compatible signed SSH plugin in Plugins/SSH first, then restart this MCP client.", code: .unsupported) }
        if tool == "ssh_list_connections" {
            let profiles = try sshConnections.load()
            return .array(profiles.filter { policy.ssh?.connectionIDs.contains($0.id) == true }.map { profile in
                var value = profile.value.objectValue ?? [:]
                value["mcp_access"] = sshAccessValue(profile, policy: policy, profiles: profiles)
                return .object(value)
            })
        }
        if tool == "ssh_add_connection" {
            let lock = try MCPComponentLock(directory: store.url.deletingLastPathComponent().appending(path: "SSHAccountOperations"))
            defer { withExtendedLifetime(lock) {} }
            let secret = args.string("password") ?? args.string("passphrase")
            let key = args.string("private_key_path")
            let authentication: SSHAuthentication?
            if let mode = args.string("authentication") {
                guard let parsed = SSHAuthentication(rawValue: mode) else { throw MCPFailure("Choose password, private_key or agent authentication.") }
                authentication = parsed
            } else { authentication = nil }
            let jump: UUID?
            if let value = args.string("jump_connection_id") {
                guard let id = UUID(uuidString: value) else { throw MCPFailure("Use an exact saved jump connection UUID.") }; jump = id
            } else { jump = nil }
            guard !(args["password"] != nil && args["passphrase"] != nil),
                  args["passphrase"] == nil || key != nil,
                  args["password"] == nil || key == nil,
                  secret.map({ !$0.contains("\0") && $0.utf8.count <= 65_536 }) ?? true else {
                throw MCPFailure("Use password authentication or a private key with an optional passphrase.")
            }
            let profile = SSHConnection(id: UUID(), name: try args.requiredString("name"), host: try args.requiredString("host"),
                port: args.integer("port", default: 22), username: try args.requiredString("username"),
                hostFingerprint: try args.requiredString("host_fingerprint"), privateKeyPath: key, storesCredential: secret != nil,
                authentication: authentication, agentSocketPath: args.string("agent_socket_path"), jumpConnectionID: jump)
            try profile.validate()
            let proposed = try sshConnections.load() + [profile]
            try SSHConnectionStore.validateRoutes(proposed)
            if let secret { try await credentials.save(password: secret, for: profile.id) }
            do {
                guard !stopped else { throw MCPFailure("MCP runtime is shutting down.") }
                let current = try store.load(); try current.authorize(tool: tool)
                try sshConnections.insert(profile)
            } catch { if secret != nil { try? await credentials.delete(for: profile.id) }; throw error }
            return .object(["connection_id": .string(profile.id.uuidString), "authorized": false,
                            "next_step": "Grant this connection explicitly in mcp-policy.json ssh.connectionIDs; command execution also requires ssh.executionConnectionIDs."])
        }
        guard let id = UUID(uuidString: try args.requiredString("connection_id")),
              let profile = try sshConnections.load().first(where: { $0.id == id }) else {
            throw MCPFailure("SSH connection not found. Use ssh_list_connections.", code: .connectionNotFound)
        }
        if MCPToolCatalog.sshTrackingTools.contains(tool) { return try await callSSHTracking(tool, args: args, profile: profile) }
        if MCPToolCatalog.sshRecoveryReads.contains(tool) || MCPToolCatalog.sshRecoveryWrites.contains(tool) { return try await callSSHRecovery(tool, args: args, profile: profile) }
        if MCPToolCatalog.sshFileReads.contains(tool) || MCPToolCatalog.sshTransfers.contains(tool) || MCPToolCatalog.sshFileWrites.contains(tool) {
            return try await callSSHFile(tool, args: args, profile: profile)
        }
        if MCPToolCatalog.sshTaskReads.contains(tool) || MCPToolCatalog.sshTaskWrites.contains(tool) {
            return try await callSSHTask(tool, args: args, profile: profile)
        }
        let execution = tool == "ssh_execute"
        guard !mutatingSSHConnections.contains(id) else { throw MCPFailure("SSH connection is being edited.", code: .sessionBusy) }
        if tool == "ssh_remove_connection" {
            let lock = try MCPComponentLock(directory: store.url.deletingLastPathComponent().appending(path: "SSHAccountOperations"))
            defer { withExtendedLifetime(lock) {} }
            guard policy.ssh?.connectionIDs.contains(id) == true else {
                throw MCPFailure("Removing an SSH connection requires an explicit connection grant.", code: .accessDenied)
            }
            guard args.flag("confirm_high_risk") else { throw MCPFailure("Removing an SSH connection requires confirm_high_risk=true.", code: .confirmationRequired) }
            guard try !sshConnections.load().contains(where: { $0.jumpConnectionID == id }) else { throw MCPFailure("This server is used as a jump host. Update its dependent connections first.") }
            guard !sshOperations.values.contains(where: { $0.profile.id == id || $0.jumps.contains(where: { $0.id == id }) }) else { throw MCPFailure("SSH connection has an active command.", code: .sessionBusy) }
            mutatingSSHConnections.insert(id)
            defer { mutatingSSHConnections.remove(id) }
            if profile.storesCredential { try await credentials.delete(for: id) }
            try sshConnections.remove(id: id)
            try store.update { SSHAccess.denied.apply(id: id, to: &$0) }
            await sshTransport?.invalidate(connectionID: id)
            return .object(["removed": true])
        }
        guard sshPermitted(profile, tool: tool, policy: policy) else {
            throw MCPFailure("SSH access is not authorized. Commands require an explicit execution grant.", code: .accessDenied)
        }
        if execution && !args.flag("confirm_high_risk") {
            throw MCPFailure("Remote shell execution requires confirm_high_risk=true after confirming the exact command.", code: .confirmationRequired)
        }
        let result = try await performSSH(profile, tool: tool, command: execution ? try args.requiredString("command") : nil,
            timeout: args.integer("timeout_seconds", default: 30), output: args.integer("max_output_bytes", default: 16_384))
        return result.value
    }

    func performSSH(_ profile: SSHConnection, tool: String, command: String? = nil, file: SSHFileRequest? = nil,
                    timeout: Int = 30, output: Int = 16_384, additionalTool: String? = nil) async throws -> SSHResult {
        let id = profile.id
        guard let sshTransport else { throw MCPFailure("Install the SSH plugin.", code: .unsupported) }
        await reconcileSSHConnections()
        let policy = try store.load()
        guard sshPermitted(profile, tool: tool, policy: policy), additionalTool.map({ sshPermitted(profile, tool: $0, policy: policy) }) ?? true else { throw MCPFailure("This SSH operation is not authorized for the connection.", code: .accessDenied) }
        guard activeConnectionCount < policy.maximumSessions else { throw MCPFailure("Connection capacity reached.", code: .capacity) }
        guard (1...300).contains(timeout), (1...1_048_576).contains(output),
              command.map({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 65_536 }) ?? true else { throw MCPFailure("Invalid SSH operation limits or command.") }
        // Reserve before fetching credentials; separate clients do not share sessions.
        pendingSSHConnections += 1
        var reserved = true
        defer { if reserved { pendingSSHConnections -= 1 } }
        let jumps = try permittedSSHRoute(profile, policy: policy, profiles: sshConnections.load())
        let configuredTimeout = policy.effectiveQueryTimeoutSeconds
        let request = try await SSHRouteRequest.make(profile: profile, jumps: jumps, credentials: credentials, command: command,
            timeoutMilliseconds: min(timeout, configuredTimeout == 0 ? timeout : configuredTimeout) * 1000,
            maximumOutputBytes: min(output, max(1, (policy.maximumResultBytes - 768) / 6)))
        try Task.checkCancellation()
        await reconcileSSHConnections()
        let current = try store.load()
        guard !stopped, !mutatingSSHConnections.contains(id), sshPermitted(profile, tool: tool, policy: current),
              try sshConnections.load().first(where: { $0.id == id }) == profile,
              additionalTool.map({ sshPermitted(profile, tool: $0, policy: current) }) ?? true,
              try permittedSSHRoute(profile, policy: current, profiles: sshConnections.load()) == jumps else {
            throw MCPFailure("SSH connection or authorization changed.", code: .accessDenied)
        }
        // Worst-case JSON escaping is six bytes per input byte. Keep room for
        // both text streams, result metadata and the protocol's own envelope.
        let budget = max(1, (current.maximumResultBytes - 768) / 6)
        // Apply a newly tightened timeout/result budget after credential awaits.
        let currentTimeout = current.effectiveQueryTimeoutSeconds
        let bounded = SSHRequest(connection: request.connection, secret: request.secret, command: request.command,
            timeoutMilliseconds: min(request.timeoutMilliseconds, (currentTimeout == 0 ? timeout : min(timeout, currentTimeout)) * 1000),
            maximumOutputBytes: min(request.maximumOutputBytes, budget), jumps: request.jumps, agentSocket: request.agentSocket)
        let operationID = UUID()
        if file != nil && budget < 256 { throw MCPFailure("Increase the MCP result budget before a file operation.", code: .resultTooLarge) }
        let task = Task {
            if let file { return try await sshTransport.executeFile(bounded, file: file) }
            return try await sshTransport.execute(bounded)
        }
        sshOperations[operationID] = SSHOperation(profile: profile, tool: tool, task: task, additionalTool: additionalTool, jumps: jumps)
        pendingSSHConnections -= 1; reserved = false
        defer { sshOperations.removeValue(forKey: operationID) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try result.validate(file: file)
        return result
    }
}
