import Foundation

/// Shared by discovery, execution checks and structured denials.
enum MCPSSHGrant: String, CaseIterable {
    case connection, execution
    case fileRead = "file_read", fileTransfer = "file_transfer", fileManagement = "file_management"

    func permits(_ id: UUID, policy: MCPPolicy) -> Bool {
        switch self {
        case .connection: policy.ssh?.connectionIDs.contains(id) == true
        case .execution: policy.ssh?.executionConnectionIDs.contains(id) == true
        case .fileRead: policy.ssh?.fileReadConnectionIDs.contains(id) == true
        case .fileTransfer: policy.ssh?.fileTransferConnectionIDs.contains(id) == true
        case .fileManagement: policy.ssh?.fileManagementConnectionIDs.contains(id) == true
        }
    }

    static func required(for tool: String, direction: String? = nil) -> [Self] {
        var grants: [Self] = [.connection]
        if MCPToolCatalog.sshFileWrites.contains(tool) { grants.append(.fileManagement) }
        else if MCPToolCatalog.sshFileReads.contains(tool) { grants.append(.fileRead) }
        else if MCPToolCatalog.sshTransfers.contains(tool) {
            grants.append(.fileTransfer)
            if tool == "ssh_download_file" { grants.append(.fileRead) }
        } else if MCPToolCatalog.sshRecoveryReads.union(MCPToolCatalog.sshRecoveryWrites).contains(tool) {
            grants.append(.fileTransfer)
            if tool == "ssh_start_transfer", direction == "download" { grants.append(.fileRead) }
        } else if tool == "ssh_execute" || MCPToolCatalog.sshTaskReads.union(MCPToolCatalog.sshTaskWrites).contains(tool) {
            grants.append(.execution)
        }
        return grants
    }
}

extension MCPRuntime {
    func sshAccessValue(_ profile: SSHConnection, policy: MCPPolicy, profiles: [SSHConnection]) -> MCPJSONValue {
        let routeAuthorized = (try? permittedSSHRoute(profile, policy: policy, profiles: profiles)) != nil
        var allowed = availableSSHTools.filter {
            $0 != "ssh_add_connection" && $0 != "ssh_list_connections" && routeAuthorized
                && sshPermitted(profile, tool: $0, policy: policy)
        }
        let directions = ["upload", "download"].filter { direction in
            let tool = direction == "upload" ? "ssh_upload_file" : "ssh_download_file"
            return allowed.contains(tool) || (allowed.contains("ssh_start_transfer")
                && sshPermitted(profile, tool: tool, policy: policy))
        }
        if directions.isEmpty { allowed.remove("ssh_start_transfer") }
        let grants = Dictionary(uniqueKeysWithValues: MCPSSHGrant.allCases.map {
            ($0.rawValue, MCPJSONValue.bool($0.permits(profile.id, policy: policy)))
        })
        let execution = MCPToolCatalog.sshTaskReads.union(MCPToolCatalog.sshTaskWrites).union(["ssh_execute"])
        return .object([
            "grants": .object(grants), "route_authorized": .bool(routeAuthorized),
            "effective_permissions": .object([
                "execution": .bool(!allowed.isDisjoint(with: execution)),
                "file_read": .bool(!allowed.isDisjoint(with: MCPToolCatalog.sshFileReads) || directions.contains("download")),
                "file_transfer": .bool(!directions.isEmpty),
                "file_management": .bool(!allowed.isDisjoint(with: MCPToolCatalog.sshFileWrites))]),
            "allowed_tools": .array(allowed.sorted().map(MCPJSONValue.string)),
            "transfer_directions": .array(directions.map(MCPJSONValue.string))
        ])
    }

    /// Decorates all direct and delegated SSH denials, including disabled tools.
    func detailedSSHFailure(_ error: any Error, name: String, args: [String: MCPJSONValue]) -> any Error {
        guard let failure = error as? MCPFailure, failure.code == .accessDenied, failure.details == nil,
              let policy = try? store.load() else { return error }
        let delegated = name == "querycraft_plugin_call"
        let tool = delegated ? args.string("tool") ?? "" : String(name.dropFirst("querycraft_".count))
        var arguments = delegated ? args["arguments"]?.objectValue ?? [:] : args
        if arguments["connection_id"] == nil { arguments["connection_id"] = args["connection_id"] }
        guard MCPToolCatalog.sshTools.contains(tool),
              let id = arguments.string("connection_id").flatMap(UUID.init(uuidString:)) else { return error }
        let required = MCPSSHGrant.required(for: tool, direction: arguments.string("direction"))
        let requiredTools = [tool] + (tool == "ssh_start_transfer" ? [arguments.string("direction") == "download" ? "ssh_download_file" : "ssh_upload_file"] : [])
        return MCPFailure(failure.message, code: failure.code, details: .object([
            "connection_id": .string(id.uuidString), "tool": .string(tool), "denial_source": "mcp_policy",
            "required_grants": .array(required.map { .string($0.rawValue) }),
            "missing_grants": .array(required.filter { !$0.permits(id, policy: policy) }.map { .string($0.rawValue) }),
            "mcp_enabled": .bool(policy.enabled), "tool_enabled": .bool(!policy.disabledTools.contains(tool)),
            "required_tools": .array(requiredTools.map(MCPJSONValue.string)),
            "disabled_tools": .array(requiredTools.filter { policy.disabledTools.contains($0) }.map(MCPJSONValue.string))
        ]))
    }
}
