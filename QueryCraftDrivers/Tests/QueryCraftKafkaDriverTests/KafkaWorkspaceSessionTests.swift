import Foundation
import Synchronization
import Testing
import QueryCraftFeature
@testable import QueryCraftKafkaDriver

@Suite("Kafka browsing lifecycle", .timeLimit(.minutes(1)))
struct KafkaWorkspaceSessionTests {
    @Test("Deleting one topic dispatches once, removes it, and rejects internal names")
    func topicDeletion() async throws {
        let fixture = KafkaClientFixture(responses: [])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: WorkspaceKafkaTopicDeletionError.self) { try await session.deleteTopic(name: "__consumer_offsets") }
        #expect(fixture.state.withLock { $0.deletedTopics.isEmpty })
        try await session.deleteTopic(name: "events")
        #expect(fixture.state.withLock { $0.deletedTopics } == ["events"])
        #expect(try await session.fetchObjects(in: "Kafka").isEmpty)
        await session.close()
        await #expect(throws: WorkspaceSessionError.self) { try await session.deleteTopic(name: "events") }
        #expect(fixture.state.withLock { $0.deletedTopics } == ["events"])
    }

    @Test("Any described writable property can be changed, while read-only metadata blocks dispatch", arguments: [false, true])
    func genericConfigurationEditing(_ readOnly: Bool) async throws {
        let fixture = KafkaClientFixture(responses: [])
        let original = WorkspaceKafkaTopicConfiguration(name: "max.message.bytes", value: "1048588", isDefault: true, isReadOnly: readOnly)
        fixture.state.withLock { $0.configurationDetails = .init(partitions: [], configurations: [original]) }
        let session = try session(fixture)
        try await session.connect()
        let request = WorkspaceKafkaTopicConfigurationRequest(topic: "events", changes: [.init(original: original, value: "2097152")])
        if readOnly {
            await #expect(throws: WorkspaceKafkaTopicConfigurationError.self) { try await session.updateTopicConfiguration(request) }
        } else {
            try await session.updateTopicConfiguration(request)
        }
        #expect(fixture.state.withLock { $0.configurationWrites } == (readOnly ? [] : [request]))
        await session.close()
    }

    @Test("Topic configuration writes validate the original snapshot and preserve browsing state")
    func editTopicConfiguration() async throws {
        let fixture = KafkaClientFixture(responses: [])
        let original = WorkspaceKafkaTopicConfiguration(name: "retention.ms", value: "1000", isDefault: false)
        fixture.state.withLock { $0.configurationDetails = .init(partitions: [], configurations: [original]) }
        let session = try session(fixture)
        try await session.connect()
        let request = WorkspaceKafkaTopicConfigurationRequest(topic: "events", changes: [.init(original: original, value: nil)])
        try await session.updateTopicConfiguration(request)
        #expect(fixture.state.withLock { $0.configurationWrites } == [request])
        #expect(fixture.state.withLock { $0.fetches.isEmpty && $0.seeks.isEmpty })
        await session.close()
        await #expect(throws: WorkspaceSessionError.self) { try await session.updateTopicConfiguration(request) }
    }

    @Test("Configuration conflicts and DescribeConfigs denial never write", arguments: [false, true])
    func configurationConflict(_ denied: Bool) async throws {
        let fixture = KafkaClientFixture(responses: [])
        let original = WorkspaceKafkaTopicConfiguration(name: "retention.ms", value: "1000", isDefault: false)
        fixture.state.withLock {
            $0.configurationDetails = .init(partitions: [], configurations: [
                .init(name: "retention.ms", value: "2000", isDefault: false)
            ], configurationError: denied ? "ACL" : nil)
        }
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: WorkspaceKafkaTopicConfigurationError.self) {
            try await session.updateTopicConfiguration(.init(topic: "events", changes: [.init(original: original, value: "3000")]))
        }
        #expect(fixture.state.withLock { $0.configurationWrites.isEmpty })
        await session.close()
    }

    private let topic = WorkspaceDatabaseObject(name: "events", kind: .table)

    private func session(_ fixture: KafkaClientFixture) throws -> KafkaWorkspaceSession {
        let configuration = try KafkaConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .kafka, databaseProduct: .kafka, host: "localhost", port: 9092,
            authentication: .none, database: nil, tlsMode: .disabled
        ))
        return KafkaWorkspaceSession(configuration: configuration, makeClient: { FixtureKafkaClient(fixture) })
    }

    private func page(_ session: KafkaWorkspaceSession, offset: Int = 0, limit: Int = 50) async throws -> [WorkspaceDatabaseDataRow] {
        let rows = KafkaRows()
        _ = try await session.fetchDataPage(for: topic, in: "Kafka", offset: offset, limit: limit, sort: .none) {
            await rows.append($0.rows)
        }
        return await rows.values
    }

    @Test("Copy reads exact raw message including binary key, null value and duplicate headers")
    func copyExactMessage() async throws {
        let message = KafkaMessage(partition: 1, offset: 80, timestamp: nil,
            key: Data([0xff, 0]), value: nil,
            headers: [.init(key: "same", value: Data("a, b=c".utf8)), .init(key: "same", value: nil)])
        let fixture = KafkaClientFixture(responses: [.success(.init(messages: [message], nextOffsets: [1: 81], exhausted: [1]))])
        let session = try session(fixture)
        try await session.connect()
        let result = try await session.messageForCopy(.init(topic: "events", partition: 1, offset: 80))
        #expect(result.key == message.key && result.value == nil)
        #expect(result.headers == [.init(name: "same", value: Data("a, b=c".utf8)), .init(name: "same", value: nil)])
        await session.close()
    }

    @Test("Copy rejects a later offset after retention or compaction")
    func copyMissingMessage() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(messages: [message(1, 81)], nextOffsets: [1: 82], exhausted: [1]))])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: WorkspaceKafkaMessageCopyError.self) { try await session.messageForCopy(.init(topic: "events", partition: 1, offset: 80)) }
        await session.close()
    }

    @Test("Consumer group reads preserve the browsing session")
    func consumerGroups() async throws {
        let fixture = KafkaClientFixture(responses: [])
        let session = try session(fixture)
        try await session.connect()
        let groups = try await session.fetchConsumerGroups()
        #expect(groups.map(\.id) == ["test-group"])
        let offsets = try await session.fetchConsumerOffsets(groupID: "test-group", topic: "events")
        #expect(offsets.first?.lag == 3)
        let details = try await session.fetchConsumerGroupDetails(groupID: "test-group", topic: "events")
        #expect(details.members.first?.partitions == [0, 1])
        #expect(details.members.first?.clientID == "reader")
        #expect(fixture.state.withLock { $0.fetches.isEmpty && $0.seeks.isEmpty })
        await session.close()
        await #expect(throws: WorkspaceSessionError.self) { try await session.fetchConsumerGroups() }
        await #expect(throws: WorkspaceSessionError.self) {
            try await session.fetchConsumerGroupDetails(groupID: "test-group", topic: "events")
        }
    }

    @Test("An empty topic finishes without repeated fetches")
    func emptyTopic() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(messages: [], nextOffsets: [0: 0, 1: 0], exhausted: [0, 1]))])
        let session = try session(fixture)
        try await session.connect()
        let result = try await session.fetchDataPage(for: topic, in: "Kafka", offset: 0, limit: 50, sort: .none) { _ in
            Issue.record("Empty topics must not emit rows")
        }
        #expect(!result.hasNextPage)
        #expect(fixture.state.withLock { $0.fetches.count } == 1)
        await session.close()
    }

    @Test("Pagination preserves partition/offset identity and does not refetch cached pages")
    func partitionsAndPagination() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(
            messages: [message(1, 0), message(0, 1), message(0, 0)],
            nextOffsets: [0: 2, 1: 1], exhausted: [0, 1]
        ))])
        let session = try session(fixture)
        try await session.connect()
        let first = try await page(session, limit: 2)
        let second = try await page(session, offset: 2, limit: 2)
        #expect(first.map { $0.values[0] } == [.text("0"), .text("0")])
        #expect(first.map { $0.values[1] } == [.text("0"), .text("1")])
        #expect(second.map { $0.values[0] } == [.text("1")])
        #expect(fixture.state.withLock { $0.fetches.count } == 1)
        await session.close()
    }

    @Test("A failed fetch can be retried at the same offsets without losing messages")
    func fetchFailureAndRetry() async throws {
        let fixture = KafkaClientFixture(responses: [
            .failure(.network("timeout")),
            .success(.init(messages: [message(0, 0)], nextOffsets: [0: 1, 1: 0], exhausted: [0, 1]))
        ])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: KafkaError.self) { try await page(session) }
        #expect(try await page(session).count == 1)
        #expect(fixture.state.withLock { $0.fetches } == [[0: 0, 1: 0], [0: 0, 1: 0]])
        await session.close()
    }

    @Test("Closing and reconnecting discards exhausted offsets and reads fresh data")
    func reconnect() async throws {
        let fixture = KafkaClientFixture(responses: [
            .success(.init(messages: [], nextOffsets: [0: 0, 1: 0], exhausted: [0, 1])),
            .success(.init(messages: [message(0, 0)], nextOffsets: [0: 1, 1: 0], exhausted: [0, 1]))
        ])
        let session = try session(fixture)
        try await session.connect()
        #expect(try await page(session).isEmpty)
        await session.close()
        #expect(await session.isConnected() == false)
        try await session.connect()
        #expect(try await page(session).count == 1)
        await session.close()
        #expect(fixture.state.withLock { $0.closeCount } == 2)
    }

    @Test("A cancelled connection never starts a client")
    func cancelledConnection() async throws {
        let fixture = KafkaClientFixture(responses: [])
        let session = try session(fixture)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.connect()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.isConnected() == false)
        #expect(fixture.state.withLock { $0.connectCount } == 0)
    }

    @Test("A cancelled read does not fetch or publish a batch")
    func cancelledRead() async throws {
        let fixture = KafkaClientFixture(responses: [])
        let session = try session(fixture)
        try await session.connect()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await page(session)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.state.withLock { $0.fetches.isEmpty })
        await session.close()
    }

    @Test("Positioning restricts partitions and keeps the same cursor on later pages")
    func positionAndPagination() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(
            messages: [message(1, 80), message(1, 81)], nextOffsets: [1: 82], exhausted: [1]
        ))])
        let session = try session(fixture)
        try await session.connect()
        let request = WorkspaceKafkaReadRequest(partition: 1, start: .offset(80))
        try await session.prepareReading(topic: "events", request: request)
        #expect(try await page(session, limit: 1).first?.values[1] == .text("80"))
        try await session.prepareReading(topic: "events", request: request)
        #expect(try await page(session, offset: 1, limit: 1).first?.values[1] == .text("81"))
        #expect(fixture.state.withLock { $0.fetches } == [[1: 80]])
        #expect(fixture.state.withLock { $0.seeks.count } == 1)
        await session.close()
    }

    @Test("A failed metadata connection is cleaned up and can reconnect")
    func failedConnectionCanReconnect() async throws {
        let fixture = KafkaClientFixture(responses: [])
        fixture.state.withLock { $0.failMetadata = true }
        let session = try session(fixture)
        await #expect(throws: KafkaError.self) { try await session.connect() }
        #expect(await session.isConnected() == false)
        #expect(fixture.state.withLock { $0.closeCount } == 1)
        fixture.state.withLock { $0.failMetadata = false }
        try await session.connect()
        #expect(await session.isConnected())
        await session.close()
    }

    @Test("Cancellation during a fetch neither publishes rows nor advances the cached cursor")
    func cancelledResultIsDiscarded() async throws {
        let result = KafkaRdkafkaFetchResult(messages: [message(0, 0)], nextOffsets: [0: 1, 1: 0], exhausted: [0, 1])
        let fixture = KafkaClientFixture(responses: [.success(result), .success(result)])
        fixture.state.withLock { $0.cancelDuringFetch = true }
        let session = try session(fixture)
        try await session.connect()
        let task = Task {
            try await session.fetchDataPage(for: topic, in: "Kafka", offset: 0, limit: 50, sort: .none) { _ in
                Issue.record("Cancelled results must not reach the table")
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        fixture.state.withLock { $0.cancelDuringFetch = false }
        #expect(try await page(session).count == 1)
        #expect(fixture.state.withLock { $0.fetches } == [[0: 0, 1: 0], [0: 0, 1: 0]])
        await session.close()
    }

    @Test("Changing position clears the previous page")
    func changePosition() async throws {
        let fixture = KafkaClientFixture(responses: [
            .success(.init(messages: [message(0, 0)], nextOffsets: [0: 1, 1: 0], exhausted: [0, 1])),
            .success(.init(messages: [message(1, 50)], nextOffsets: [1: 51], exhausted: [1]))
        ])
        let session = try session(fixture)
        try await session.connect()
        #expect(try await page(session).count == 1)
        try await session.prepareReading(topic: "events", request: .init(partition: 1, start: .offset(50)))
        let rows = try await page(session)
        #expect(rows.count == 1)
        #expect(rows.first?.values[1] == .text("50"))
        await session.close()
    }

    @Test("Scan budgets count nonmatching records and pagination never scans again")
    func boundedScan() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(
            messages: [message(0, 0), message(1, 0), message(0, 1)],
            nextOffsets: [0: 2, 1: 1], exhausted: []
        ))])
        let session = try session(fixture)
        try await session.connect()
        let request = WorkspaceKafkaScanRequest(text: "absent", maximumMessages: 2)
        let progress = KafkaScanProgressLog()
        try await session.prepareScanning(topic: "events", request: request) { await progress.append($0) }
        #expect(await progress.last?.scanned == 2)
        #expect(await progress.last?.matched == 0)
        #expect(await progress.last?.status == .messageLimit)
        #expect(try await page(session).isEmpty)
        try await session.prepareScanning(topic: "events", request: request) { await progress.append($0) }
        #expect(fixture.state.withLock { $0.fetches.count } == 1)
        await session.close()
    }

    @Test("Scan continues across batches, preserves partition scope and paginates matching rows")
    func scanningPages() async throws {
        let fixture = KafkaClientFixture(responses: [
            .success(.init(messages: [message(1, 80)], nextOffsets: [1: 81], exhausted: [])),
            .success(.init(messages: [message(1, 81)], nextOffsets: [1: 82], exhausted: [1]))
        ])
        let session = try session(fixture)
        try await session.connect()
        try await session.prepareReading(topic: "events", request: .init(partition: 1, start: .offset(80)))
        let progress = KafkaScanProgressLog()
        let scan = WorkspaceKafkaScanRequest(match: .exact, text: "VALUE")
        try await session.prepareScanning(topic: "events", request: scan) { await progress.append($0) }
        #expect(await progress.last?.status == .reachedEnd)
        #expect(await progress.last?.scanned == 2)
        #expect(await progress.last?.matched == 2)
        #expect(try await page(session, limit: 1).first?.values[1] == .text("80"))
        #expect(try await page(session, offset: 1, limit: 1).first?.values[1] == .text("81"))
        #expect(fixture.state.withLock { $0.fetches } == [[1: 80], [1: 81]])
        await session.close()
    }

    @Test("Cancellation during scan progress preserves the old browsing cache")
    func cancelledScanPreservesCache() async throws {
        let fixture = KafkaClientFixture(responses: [
            .success(.init(messages: [message(0, 99)], nextOffsets: [0: 100], exhausted: [0, 1])),
            .success(.init(messages: [message(0, 0)], nextOffsets: [0: 1, 1: 0], exhausted: []))
        ])
        let session = try session(fixture)
        try await session.connect()
        #expect(try await page(session).first?.values[1] == .text("99"))
        let task = Task {
            try await session.prepareScanning(topic: "events", request: .init(text: "value")) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await page(session).first?.values[1] == .text("99"))
        #expect(fixture.state.withLock { $0.fetches.count } == 2)
        await session.close()
    }

    @Test("Closing during a progress callback cannot publish stale scan results")
    func closedScan() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(
            messages: [message(0, 0)], nextOffsets: [0: 1], exhausted: [0, 1]
        ))])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: CancellationError.self) {
            try await session.prepareScanning(topic: "events", request: .init(text: "value")) { _ in
                await session.close()
            }
        }
        #expect(await session.isConnected() == false)
    }

    @Test("Changing position during a scan prevents stale results from replacing the new cursor")
    func changedPositionCancelsScan() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(
            messages: [message(0, 0)], nextOffsets: [0: 1], exhausted: [0, 1]
        )), .success(.init(messages: [message(1, 80)], nextOffsets: [1: 81], exhausted: [1]))])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: CancellationError.self) {
            try await session.prepareScanning(topic: "events", request: .init(text: "value")) { _ in
                try? await session.prepareReading(topic: "events", request: .init(partition: 1, start: .offset(80)))
            }
        }
        #expect(try await page(session).first?.values[1] == .text("80"))
        await session.close()
    }

    @Test("A scan that cannot advance fails instead of declaring an empty success")
    func stalledScan() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(messages: [], nextOffsets: [0: 0, 1: 0], exhausted: []))])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: KafkaError.self) {
            try await session.prepareScanning(topic: "events", request: .init(text: "value")) { _ in }
        }
        #expect(fixture.state.withLock { $0.fetches.count } == 1)
        await session.close()
    }

    @Test("Scan failures can be retried from the original start")
    func retryScan() async throws {
        let fixture = KafkaClientFixture(responses: [
            .failure(.network("timeout")),
            .success(.init(messages: [], nextOffsets: [0: 0, 1: 0], exhausted: [0, 1]))
        ])
        let session = try session(fixture)
        try await session.connect()
        await #expect(throws: KafkaError.self) {
            try await session.prepareScanning(topic: "events", request: .init(text: "value")) { _ in }
        }
        let progress = KafkaScanProgressLog()
        try await session.prepareScanning(topic: "events", request: .init(text: "value")) { await progress.append($0) }
        #expect(await progress.last?.status == .reachedEnd)
        #expect(await progress.last?.scanned == 0)
        #expect(fixture.state.withLock { $0.fetches } == [[0: 0, 1: 0], [0: 0, 1: 0]])
        await session.close()
    }

    @Test("Live filtering advances the cursor and received count for nonmatching messages")
    func liveFilter() async throws {
        let fixture = KafkaClientFixture(responses: [.success(.init(
            messages: [message(0, 10), message(0, 11)], nextOffsets: [0: 12], exhausted: []
        ))])
        let session = try session(fixture)
        try await session.connect()
        let result = try await session.pollTail(topic: "events", offsets: [0: 10], filter: .init(text: "absent"))
        #expect(result.received == 2 && result.data.rows.isEmpty)
        #expect(result.nextOffsets == [0: 12])
        await session.close()
    }

    private func message(_ partition: Int32, _ offset: Int64) -> KafkaMessage {
        KafkaMessage(partition: partition, offset: offset, timestamp: nil, key: nil, value: Data("value".utf8), headers: [])
    }
}

private actor KafkaScanProgressLog {
    var last: WorkspaceKafkaScanProgress?
    func append(_ progress: WorkspaceKafkaScanProgress) { last = progress }
}

private actor KafkaRows {
    var values: [WorkspaceDatabaseDataRow] = []
    func append(_ rows: [WorkspaceDatabaseDataRow]) { values.append(contentsOf: rows) }
}

private final class KafkaClientFixture: Sendable {
    struct State {
        var responses: [Result<KafkaRdkafkaFetchResult, KafkaError>]
        var fetches: [[Int32: Int64]] = []
        var seeks: [WorkspaceKafkaReadRequest] = []
        var connectCount = 0
        var closeCount = 0
        var failMetadata = false
        var cancelDuringFetch = false
        var configurationDetails: WorkspaceKafkaTopicDetails?
        var configurationWrites: [WorkspaceKafkaTopicConfigurationRequest] = []
        var deletedTopics: [String] = []
    }
    let state: Mutex<State>
    init(responses: [Result<KafkaRdkafkaFetchResult, KafkaError>]) {
        state = Mutex(State(responses: responses))
    }
}

private final class FixtureKafkaClient: KafkaClient {
    let fixture: KafkaClientFixture
    var connected = false
    init(_ fixture: KafkaClientFixture) { self.fixture = fixture }
    func connect() throws { connected = true; fixture.state.withLock { $0.connectCount += 1 } }
    func close() { connected = false; fixture.state.withLock { $0.closeCount += 1 } }
    func isConnected() -> Bool { connected }
    func pollTail(topic: String, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult {
        try fetch(topic: topic, offsets: offsets)
    }
    func metadata() throws -> KafkaRdkafkaMetadata {
        if fixture.state.withLock({ $0.failMetadata }) { throw KafkaError.network("metadata timeout") }
        if fixture.state.withLock({ $0.deletedTopics.contains("events") }) { return .init(brokers: [:], topics: []) }
        return .init(brokers: [:], topics: [.init(name: "events", partitions: [
            .init(partition: 0, leader: 0), .init(partition: 1, leader: 0)
        ])])
    }
    func createTopic(name: String, partitions: Int32, replicationFactor: Int16) throws {}
    func deleteTopic(name: String) throws { fixture.state.withLock { $0.deletedTopics.append(name) } }
    func consumerGroups() throws -> [WorkspaceKafkaConsumerGroup] { [.init(id: "test-group", state: "Stable")] }
    func consumerGroupDetails(groupID: String, topic: String) throws -> WorkspaceKafkaConsumerGroupDetails {
        .init(state: "Stable", assignor: "range", members: [
            .init(id: "member-1", clientID: "reader", host: "/127.0.0.1", instanceID: "instance-1", partitions: [0, 1])
        ])
    }
    func topicDetails(topic: String) throws -> WorkspaceKafkaTopicDetails {
        fixture.state.withLock { $0.configurationDetails } ?? .init(partitions: [.init(id: 0, leader: 1, replicas: [1, 2], inSyncReplicas: [1])],
              configurations: [], configurationError: "Not authorized")
    }
    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) throws {
        fixture.state.withLock { $0.configurationWrites.append(request) }
    }
    func groupTopicMembership(groupID: String, topic: String, partitions: [Int32]) throws -> WorkspaceKafkaGroupTopicMembership {
        groupID == "test-group" && topic == "events" && partitions == [0, 1] ? .related : .unknown
    }
    func consumerOffsets(groupID: String, topic: String) throws -> [WorkspaceKafkaConsumerOffset] {
        [.init(partition: 0, committedOffset: 2, beginningOffset: 0, endOffset: 5)]
    }
    func startingOffsets(topic: String, request: WorkspaceKafkaReadRequest) throws -> [Int32: Int64] {
        fixture.state.withLock { $0.seeks.append(request) }
        let offset: Int64 = if case .offset(let value) = request.start { value } else { 0 }
        return Dictionary(uniqueKeysWithValues: (request.partition.map { [$0] } ?? [0, 1]).map { ($0, offset) })
    }
    func fetch(topic: String, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult {
        try fixture.state.withLock {
            $0.fetches.append(offsets)
            if $0.cancelDuringFetch { withUnsafeCurrentTask { $0?.cancel() } }
            guard !$0.responses.isEmpty else { throw KafkaError.network("Unexpected fetch") }
            return try $0.responses.removeFirst().get()
        }
    }
}
