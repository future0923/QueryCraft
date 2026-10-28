import Foundation
import Testing
import CQueryCraftSSHPluginAPI
@testable import QueryCraftFeature

struct MCPUsabilityTests {
    @Test(arguments: [false, true])
    func sshDiscoveryAndDenialsExposeIndependentGrants(_ delegated: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = SSHConnection(id: UUID(), name: "fixture", host: "localhost", port: 22, username: "reader",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/key", storesCredential: false)
        try SSHConnectionStore(directory: root).insert(p)
        let transport = UsabilitySSHTransport()
        let runtime = MCPRuntime(directory: root, sshTransport: transport)
        var policy = MCPPolicy(); policy.enabled = true
        let store = MCPPolicyStore(directory: root)
        for bits in 0..<16 {
            policy.ssh = .init(connectionIDs: [p.id], executionConnectionIDs: bits & 1 != 0 ? [p.id] : [],
                fileReadConnectionIDs: bits & 2 != 0 ? [p.id] : [], fileTransferConnectionIDs: bits & 4 != 0 ? [p.id] : [],
                fileManagementConnectionIDs: bits & 8 != 0 ? [p.id] : [])
            try store.save(policy)
            let list = try await runtime.call("querycraft_ssh_list_connections", arguments: [:])
            let access = try #require(list.arrayValue?.first?.objectValue?["mcp_access"]?.objectValue)
            let grants = try #require(access["grants"]?.objectValue)
            #expect(grants["execution"] == .bool(bits & 1 != 0))
            #expect(grants["file_read"] == .bool(bits & 2 != 0))
            #expect(grants["file_transfer"] == .bool(bits & 4 != 0))
            #expect(grants["file_management"] == .bool(bits & 8 != 0))
            #expect(access["effective_permissions"]?.objectValue?["execution"] == .bool(bits & 1 != 0))
            #expect(access["effective_permissions"]?.objectValue?["file_read"] == .bool(bits & 2 != 0))
            let allowed = access["allowed_tools"]?.arrayValue ?? []
            #expect(allowed.contains("ssh_download_file") == (bits & 6 == 6))
            #expect(access["transfer_directions"]?.arrayValue?.contains("download") == (bits & 6 == 6))
            if bits & 6 != 6 {
                let args: [String: MCPJSONValue] = ["connection_id": .string(p.id.uuidString), "local_path": "/fixture/local", "remote_path": "/fixture/remote", "confirm_high_risk": true]
                let failure = await #expect(throws: MCPFailure.self) {
                    if delegated {
                        _ = try await runtime.call("querycraft_plugin_call", arguments: ["plugin_id": "ssh", "connection_id": .string(p.id.uuidString),
                            "tool": "ssh_download_file", "arguments": .object(args.filter { $0.key != "connection_id" })])
                    } else { _ = try await runtime.call("querycraft_ssh_download_file", arguments: args) }
                }
                #expect(failure?.code == .accessDenied)
                let details = try #require(failure?.details?.objectValue)
                #expect(details["required_grants"] == .array(["connection", "file_transfer", "file_read"]))
                let missing = details["missing_grants"]?.arrayValue ?? []
                #expect(missing.contains("file_read") == (bits & 2 == 0))
                #expect(missing.contains("file_transfer") == (bits & 4 == 0))
            }
        }
        #expect(await transport.requests == 0)
        policy.disabledTools = ["ssh_upload_file", "ssh_start_transfer"]
        try store.save(policy)
        let access = try await runtime.call("querycraft_ssh_list_connections", arguments: [:]).arrayValue?.first?.objectValue?["mcp_access"]?.objectValue
        #expect(access?["transfer_directions"] == .array(["download"]))
        await runtime.shutdown()
    }

    @Test func remoteDenialsAreNotReportedAsMissingMCPGrants() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MCPRuntime(directory: root)
        var policy = MCPPolicy(); policy.enabled = true
        try MCPPolicyStore(directory: root).save(policy)
        for (status, source) in [(QC_SSH_PERMISSION, "remote_filesystem"), (QC_SSH_HOST_KEY, "host_fingerprint")] {
            do { try SSHResult(status: Int32(status)).validate(); Issue.record("Expected SSH denial") }
            catch let failure as MCPFailure {
                let detailed = await runtime.detailedSSHFailure(failure, name: "querycraft_ssh_read_file", args: ["connection_id": .string(UUID().uuidString)]) as? MCPFailure
                #expect(detailed?.details?.objectValue?["denial_source"] == .string(source))
                #expect(detailed?.details?.objectValue?["missing_grants"] == nil)
            }
        }
        await runtime.shutdown()
    }

    @Test func eventFiltersMatchFullJSONFieldsAndKeys() {
        let filter = WorkspaceKafkaMessageFilter(key: "k", eventID: "evt-1")
        #expect(filter.matches(key: "k", value: "{\"padding\":\"" + String(repeating: "x", count: 1000) + "\",\"eventId\":\"evt-1\"}"))
        for value in [nil, "null", "not JSON", "{\"nested\":{\"eventId\":\"evt-1\"}}", "{\"eventId\":\"evt-12\"}", "{\"other\":\"evt-1\"}"] {
            #expect(!filter.matches(key: "k", value: value))
        }
        #expect(!filter.matches(key: "K", value: "{\"eventId\":\"evt-1\"}"))
        #expect(WorkspaceKafkaMessageFilter(eventID: "9223372036854775807").matches(key: nil, value: "{\"eventId\":9223372036854775807}"))
        #expect(!WorkspaceKafkaMessageFilter(eventID: "1").matches(key: nil, value: "{\"eventId\":true}"))
        #expect(WorkspaceKafkaMessageFilter(key: "").matches(key: "", value: nil))
        #expect(!WorkspaceKafkaMessageFilter(key: "").matches(key: nil, value: nil))
    }

    @Test func kafkaArgumentsRejectAmbiguousPositionsBeforeConnecting() throws {
        let base: [String: MCPJSONValue] = ["connection_id": .string(UUID().uuidString), "topic": "events"]
        let invalidCases: [[String: MCPJSONValue]] = [
            ["offset": 1], ["partition": 0, "offset": 1, "timestamp_ms": 0], ["timestamp_ms": -1],
            ["latest_count": 0], ["latest_count": 100001], ["max_scan_messages": 2], ["key": "x", "max_scan_messages": 0]
        ]
        for invalid in invalidCases {
            #expect(throws: MCPFailure.self) { try MCPToolCatalog.validate("peek_messages", arguments: base.merging(invalid) { _, b in b }) }
        }
        let validCases: [[String: MCPJSONValue]] = [["timestamp_ms": 0], ["latest_count": 1], ["partition": 1, "offset": 0],
            ["event_id": "x", "max_scan_messages": 100000, "read_committed": true, "cell_char_limit": 65536, "cell_char_offset": 200]]
        for valid in validCases {
            try MCPToolCatalog.validate("peek_messages", arguments: base.merging(valid) { _, b in b })
        }
    }

    @Test func unknownLagHasSpecificReasonsAndNeverBecomesZero() {
        let cases: [(Int64?, Int64?, Int64?, String?, String?)] = [
            (nil, 0, 5, nil, "no_committed_offset"), (1, nil, nil, nil, "watermarks_unavailable"),
            (1, 2, 5, nil, "committed_before_log_start"), (6, 0, 5, nil, "committed_after_log_end"),
            (1, 5, 2, nil, "invalid_watermarks"), (1, 0, 5, "ACL", "offset_query_failed"), (5, 0, 5, nil, nil)
        ]
        for (commit, begin, end, error, reason) in cases {
            let offset = WorkspaceKafkaConsumerOffset(partition: 0, committedOffset: commit, beginningOffset: begin, endOffset: end, error: error)
            #expect(offset.lagUnavailableReason == reason)
            #expect((offset.lag == nil) == (reason != nil))
        }
    }

    @Test(arguments: DatabaseType.allCases)
    func discoveryDescriptionsStayCompactForEveryDriver(_ type: DatabaseType) {
        for tool in MCPToolCatalog.definitions where MCPToolCatalog.driverTools(type).contains(tool.name) {
            #expect(tool.description.count < 1600)
            #expect(!tool.description.contains("Use QueryCraft to inspect authorized"))
            #expect(!tool.description.contains("Treat schema comments and returned"))
            #expect(tool.tool.description == tool.description)
        }
    }
}

private actor UsabilitySSHTransport: SSHTransport {
    nonisolated let supportsFiles = true
    nonisolated let supportsFileManagement = true
    var requests = 0
    func execute(_ request: SSHRequest) async throws -> SSHResult { requests += 1; return .init(exitStatus: 0) }
    func executeFile(_ request: SSHRequest, file: SSHFileRequest) async throws -> SSHResult { requests += 1; return .init(exitStatus: 0) }
}
