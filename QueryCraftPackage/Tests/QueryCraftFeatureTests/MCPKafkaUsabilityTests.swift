import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPKafkaUsabilityTests {
    @Test(arguments: [false, true], [false, true])
    func messageOptionsReachDriverAndReturnWindows(_ delegated: Bool, _ bounded: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: root).save(policy)
        let probe = KafkaUsabilityProbe(bounded: bounded)
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [UsabilityKafkaDriver(probe: probe)]))
        let p = MCPTests().profile(type: .kafka); try await runtime.repository.insert(p)
        var args: [String: MCPJSONValue] = ["topic": "events", "partition": 1, "read_committed": true,
            "key": "k", "event_id": "evt-1", "max_scan_messages": 2, "cell_char_offset": 200, "cell_char_limit": 400]
        if bounded { args["timestamp_ms"] = 1234567890123 } else { args["latest_count"] = 10 }
        let result: MCPJSONValue
        if delegated {
            result = try await runtime.call("querycraft_plugin_call", arguments: ["connection_id": .string(p.id.uuidString), "tool": "peek_messages", "arguments": .object(args)])
        } else {
            args["connection_id"] = .string(p.id.uuidString)
            result = try await runtime.call("querycraft_peek_messages", arguments: args)
        }
        #expect(await probe.requests == [.init(partition: 1, start: bounded ? .timestamp(1234567890123) : .latest(10))])
        #expect(await probe.filters == [.init(key: "k", eventID: "evt-1", maximumMessages: 2)])
        #expect(await probe.steps.prefix(2) == ["isolation:read_committed", "connect"])
        #expect(result.objectValue?["read_isolation"] == "read_committed")
        #expect(result.objectValue?["scan"]?.objectValue?["complete"] == .bool(!bounded))
        #expect(result.objectValue?["truncated"] == .bool(bounded))
        let cell = try #require(result.objectValue?["rows"]?.arrayValue?.first?.arrayValue?.first?.objectValue)
        #expect(cell["text"]?.stringValue?.count == 400)
        #expect(cell["offset"] == 200 && cell["next_offset"] == 600)
        #expect(await probe.closed)
        await runtime.shutdown()
    }

    @Test(arguments: [false, true])
    func oldDriverRejectsUnsupportedOptionsWithoutPretendingToFilter(_ isolation: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: root).save(policy)
        let probe = KafkaUsabilityProbe()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [UsabilityKafkaDriver(probe: probe, legacy: true)]))
        let p = MCPTests().profile(type: .kafka); try await runtime.repository.insert(p)
        var args: [String: MCPJSONValue] = ["connection_id": .string(p.id.uuidString), "topic": "events"]
        args[isolation ? "read_committed" : "event_id"] = isolation ? true : "evt-1"
        let failure = await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_peek_messages", arguments: args) }
        #expect(failure?.code == .unsupported)
        #expect(await probe.dataReads == 0)
        #expect(await probe.closed)
        await runtime.shutdown()
    }

    @Test func consumerGroupResponseKeepsExactOffsetsAndUnknownReasons() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        try MCPPolicyStore(directory: root).save(policy)
        let probe = KafkaUsabilityProbe()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [UsabilityKafkaDriver(probe: probe)]))
        let p = MCPTests().profile(type: .kafka); try await runtime.repository.insert(p)
        let result = try await runtime.call("querycraft_consumer_groups", arguments: ["connection_id": .string(p.id.uuidString), "topic": "events"])
        let parts = try #require(result.arrayValue?.first?.objectValue?["partitions"]?.arrayValue)
        #expect(parts[0].objectValue?["committed_offset"] == "9007199254740993")
        #expect(parts[0].objectValue?["beginning_offset"] == "9007199254740990")
        #expect(parts[0].objectValue?["end_offset"] == "9007199254740995")
        #expect(parts[0].objectValue?["lag"] == "2")
        #expect(parts[0].objectValue?["lag_reason"] == .null)
        #expect(parts[1].objectValue?["lag"] == .null)
        #expect(parts[1].objectValue?["lag_reason"] == "no_committed_offset")
        #expect(parts[2].objectValue?["lag_reason"] == "offset_query_failed")
        #expect(parts[2].objectValue?["error"] == "ACL")
        await runtime.shutdown()
    }
}

private struct UsabilityKafkaDriver: DatabaseDriver {
    let databaseType = DatabaseType.kafka
    let probe: KafkaUsabilityProbe
    var legacy = false
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession {
        if legacy { return LegacyUsabilityKafkaSession(probe: probe) }
        return CurrentUsabilityKafkaSession(probe: probe)
    }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}

private actor KafkaUsabilityProbe {
    let bounded: Bool
    var steps: [String] = []
    var requests: [WorkspaceKafkaReadRequest] = []
    var filters: [WorkspaceKafkaMessageFilter] = []
    var closed = false
    var dataReads = 0
    init(bounded: Bool = false) { self.bounded = bounded }
    func step(_ value: String) { steps.append(value) }
    func read(_ request: WorkspaceKafkaReadRequest) { requests.append(request) }
    func search(_ filter: WorkspaceKafkaMessageFilter) -> WorkspaceKafkaScanProgress {
        filters.append(filter)
        return .init(scanned: 2, matched: 1, status: bounded ? .messageLimit : .reachedEnd)
    }
    func close() { closed = true }
    func data() -> WorkspaceDatabaseDataBatch {
        dataReads += 1
        return .init(columns: [.init(id: 0, name: "value", type: "TEXT")], rows: [.init(id: 0, values: [.text(String(repeating: "x", count: 1000))])])
    }
}

private protocol UsabilityKafkaSession: WorkspaceSession, WorkspaceKafkaReading, WorkspaceKafkaConsumerGroupProviding {
    var probe: KafkaUsabilityProbe { get }
}
private extension UsabilityKafkaSession {
    func connect() async throws { await probe.step("connect") }
    func isConnected() async -> Bool { true }
    func close() async { await probe.close() }
    func fetchDatabases() async throws -> [String] { ["Kafka"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [.init(name: "events", kind: .table)] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { .init(columns: [], ddl: "") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 1 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult {
        let data = await probe.data(); await onBatch(data)
        return .init(columns: data.columns, hasNextPage: false)
    }
    func executeReadOnlyQuery(_ sql: String, database: String?, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> WorkspaceQueryExecutionResult { .init(columns: [], rowCount: 0) }
    func prepareReading(topic: String, request: WorkspaceKafkaReadRequest) async throws { await probe.read(request) }
    func fetchConsumerGroups() async throws -> [WorkspaceKafkaConsumerGroup] { [.init(id: "g", state: "Empty")] }
    func fetchConsumerOffsets(groupID: String, topic: String) async throws -> [WorkspaceKafkaConsumerOffset] {
        [.init(partition: 0, committedOffset: 9007199254740993, beginningOffset: 9007199254740990, endOffset: 9007199254740995),
         .init(partition: 1, committedOffset: nil, beginningOffset: 0, endOffset: 5),
         .init(partition: 2, committedOffset: nil, beginningOffset: nil, endOffset: nil, error: "ACL")]
    }
}
private actor LegacyUsabilityKafkaSession: UsabilityKafkaSession {
    nonisolated let probe: KafkaUsabilityProbe
    init(probe: KafkaUsabilityProbe) { self.probe = probe }
}
private actor CurrentUsabilityKafkaSession: UsabilityKafkaSession, WorkspaceKafkaMessageSearching, WorkspaceKafkaReadIsolationConfiguring {
    nonisolated let probe: KafkaUsabilityProbe
    init(probe: KafkaUsabilityProbe) { self.probe = probe }
    func configureReadIsolation(_ isolation: WorkspaceKafkaReadIsolation) async throws { await probe.step("isolation:" + isolation.rawValue) }
    func prepareMessageSearch(topic: String, filter: WorkspaceKafkaMessageFilter) async throws -> WorkspaceKafkaScanProgress { await probe.search(filter) }
}
