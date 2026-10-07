import Foundation
import CRdkafka
import Testing
import QueryCraftFeature
@testable import QueryCraftKafkaDriver

@Suite("Kafka native navigation", .timeLimit(.minutes(1)),
       .enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_FIXTURE"] != nil))
struct KafkaNavigationIntegrationTests {
    @Test("Unsupported incremental configuration API reports failure instead of silent success")
    func unsupportedConfigurationUpdate() throws {
        let client = try client()
        defer { client.close() }
        // librdkafka's mock broker does not support IncrementalAlterConfigs.
        let original = WorkspaceKafkaTopicConfiguration(name: "retention.ms", value: "1000", isDefault: false)
        #expect(throws: KafkaError.self) {
            try client.updateTopicConfiguration(.init(topic: "qc-navigation", changes: [.init(original: original, value: "2000")]))
        }
    }

    @Test("Producer reports delivery partition and offset and preserves UTF-8, empty keys and duplicate headers")
    func produceAndReadBack() throws {
        let client = try client()
        defer { client.close() }
        let headers: [WorkspaceKafkaProducerHeader] = [
            .init(name: "trace", value: Data("测试".utf8)),
            .init(name: "trace", value: Data()), .init(name: "nullable", value: nil),
            .init(name: "binary", value: Data([0xff, 0]))
        ]
        let payload = Data("{\"message\":\"你好 Kafka\"}".utf8)
        let first = try client.produce(.init(topic: "qc-produce", partition: 1, key: Data(), value: payload, headers: headers))
        #expect(first.partition == 1 && first.offset == 0)
        let second = try client.produce(.init(topic: "qc-produce", partition: 1, key: nil, value: Data()))
        #expect(second.partition == 1 && second.offset == 1)
        let tombstone = try client.produce(.init(topic: "qc-produce", partition: 1, key: Data([0xff, 0]),
                                                 value: Data(), isNullValue: true))
        #expect(tombstone.partition == 1 && tombstone.offset == 2)
        let result = try client.fetch(topic: "qc-produce", offsets: [1: 0])
        #expect(result.messages.count == 3)
        let message = try #require(result.messages.first)
        #expect(message.value == payload && message.key == Data())
        #expect(message.headers.map(\.key) == headers.map(\.name))
        #expect(message.headers.map(\.value) == headers.map(\.value))
        #expect(result.messages[1].key == nil)
        #expect(result.messages[1].value == Data())
        #expect(result.messages.last?.key == Data([0xff, 0]))
        #expect(result.messages.last?.value == nil)
        let automatic = try client.produce(.init(topic: "qc-produce", value: Data("automatic".utf8)))
        #expect([0, 1].contains(automatic.partition) && automatic.offset != nil)
        #expect(throws: WorkspaceKafkaProduceError.self) {
            try client.produce(.init(topic: "qc-produce", partition: 99, value: payload))
        }
        #expect(throws: WorkspaceKafkaProduceError.self) {
            try client.produce(.init(topic: "qc-missing-produce", value: payload))
        }
        #expect(!((try client.metadata()).topics.contains { $0.name == "qc-missing-produce" }))
    }

    @Test("Native live reads idle topics and resumes at the saved offset without replaying messages")
    func liveReadAndResume() throws {
        let first = try client()
        let start = try first.tailStartingOffsets(topic: "qc-live", partition: 0)
        #expect(start == [0: 0])
        let idle = try first.pollTail(topic: "qc-live", offsets: start)
        #expect(idle.messages.isEmpty && idle.nextOffsets == start)
        try produceLive("first")
        let received = try awaitLive(first, offsets: start)
        #expect(received.messages.map(\.offset) == [0])
        #expect(received.messages.first?.value == Data("first".utf8))
        first.close()
        try produceLive("second")
        let resumed = try client()
        defer { resumed.close() }
        let next = try awaitLive(resumed, offsets: received.nextOffsets)
        #expect(next.messages.map(\.offset) == [1])
        #expect(next.messages.first?.value == Data("second".utf8))
        #expect(throws: KafkaError.self) { try resumed.pollTail(topic: "qc-live", offsets: [0: 999]) }
    }

    private func awaitLive(_ client: KafkaRdkafkaClient, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let result = try client.pollTail(topic: "qc-live", offsets: offsets)
            if !result.messages.isEmpty { return result }
        }
        throw KafkaError.network("Live fixture timed out")
    }

    private func produceLive(_ value: String) throws {
        let bootstrap = try #require(ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_FIXTURE"])
        let conf = try #require(rd_kafka_conf_new())
        var error = [CChar](repeating: 0, count: 512)
        #expect(rd_kafka_conf_set(conf, "bootstrap.servers", bootstrap, &error, error.count) == RD_KAFKA_CONF_OK)
        let producer = try #require(rd_kafka_new(RD_KAFKA_PRODUCER, conf, &error, error.count))
        defer { rd_kafka_destroy(producer) }
        let topic = try #require(rd_kafka_topic_new(producer, "qc-live", nil))
        defer { rd_kafka_topic_destroy(topic) }
        var bytes = Array(value.utf8)
        let count = bytes.count
        let result = bytes.withUnsafeMutableBytes {
            rd_kafka_produce(topic, 0, Int32(RD_KAFKA_MSG_F_COPY), $0.baseAddress, count, nil, 0, nil)
        }
        #expect(result == 0)
        #expect(rd_kafka_flush(producer, 5_000) == RD_KAFKA_RESP_ERR_NO_ERROR)
    }

    private func client() throws -> KafkaRdkafkaClient {
        let bootstrap = try #require(ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_FIXTURE"])
        let configuration = try KafkaConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .kafka, databaseProduct: .kafka, host: bootstrap, port: 9092,
            authentication: .none, database: nil, tlsMode: .disabled))
        let client = KafkaRdkafkaClient(configuration: configuration)
        try client.connect()
        return client
    }

    @Test("Consumer lag reads committed positions without committing or consuming")
    func consumerLag() throws {
        let client = try client()
        defer { client.close() }
        let first = try client.consumerOffsets(groupID: "qc-lag", topic: "qc-navigation")
        #expect(first.map(\.committedOffset) == [3, 7])
        #expect(first.map(\.lag) == [7, 3])
        #expect(try client.groupTopicMembership(groupID: "qc-lag", topic: "qc-navigation", partitions: [0, 1]) == .related)
        _ = try client.fetch(topic: "qc-navigation", offsets: [0: 0, 1: 0])
        #expect(try client.consumerOffsets(groupID: "qc-lag", topic: "qc-navigation") == first)
        let uncommitted = try client.consumerOffsets(groupID: "qc-lag", topic: "qc-empty")
        #expect(uncommitted.count == 1)
        #expect(uncommitted[0].committedOffset == nil)
        #expect(uncommitted[0].lag == nil)
    }

    @Test("Partition metadata remains available when DescribeConfigs is unsupported")
    func topicDetailsWithoutConfigs() throws {
        let client = try client()
        defer { client.close() }
        let details = try client.topicDetails(topic: "qc-navigation")
        #expect(details.partitions.map(\.id) == [0, 1])
        #expect(details.partitions.allSatisfy { $0.leader != nil && !$0.replicas.isEmpty })
        #expect(details.configurationError != nil || !details.configurations.isEmpty)
    }

    @Test("Cold native fetch reads both partitions without manual retry")
    func coldFetch() throws {
        let client = try client()
        defer { client.close() }
        let result = try client.fetch(topic: "qc-navigation", offsets: [0: 0, 1: 0])
        #expect(!result.messages.isEmpty)
        #expect(result.messages.allSatisfy { $0.offset >= 0 && $0.offset < 10 })
    }

    @Test("Native latest positioning reads the tail of each partition")
    func latest() throws {
        let client = try client()
        defer { client.close() }
        let offsets = try client.startingOffsets(topic: "qc-navigation", request: .init(start: .latest(3)))
        #expect(offsets == [0: 7, 1: 7])
        let result = try client.fetch(topic: "qc-navigation", offsets: offsets)
        #expect(!result.messages.isEmpty)
        #expect(result.messages.allSatisfy { $0.offset >= 7 && $0.offset < 10 })
    }

    @Test("Native offset positioning restricts reads to the requested partition")
    func offset() throws {
        let client = try client()
        defer { client.close() }
        let offsets = try client.startingOffsets(topic: "qc-navigation", request: .init(partition: 1, start: .offset(5)))
        #expect(offsets == [1: 5])
        let result = try client.fetch(topic: "qc-navigation", offsets: offsets)
        #expect(result.messages.map(\.offset) == [5, 6, 7, 8, 9])
        #expect(result.messages.allSatisfy { $0.partition == 1 })
    }

    @Test("Native empty topic finishes without polling for messages")
    func empty() throws {
        let client = try client()
        defer { client.close() }
        let result = try client.fetch(topic: "qc-empty", offsets: [0: 0])
        #expect(result.messages.isEmpty)
        #expect(result.exhausted == [0])
    }

    @Test("Native scan fetch respects its exact remaining message budget")
    func nativeFetchBudget() throws {
        let client = try client()
        defer { client.close() }
        let result = try client.fetch(topic: "qc-navigation", offsets: [1: 0], maximumMessages: 3)
        #expect(result.messages.map(\.offset) == [0, 1, 2])
        #expect(result.nextOffsets[1] == 3)
        #expect(!result.exhausted.contains(1))
        let next = try client.fetch(topic: "qc-navigation", offsets: result.nextOffsets, maximumMessages: 2)
        #expect(next.messages.map(\.offset) == [3, 4])
    }

    @Test("Native timestamp lookup yields usable partition offsets")
    func timestamp() throws {
        let client = try client()
        defer { client.close() }
        let offsets = try client.startingOffsets(topic: "qc-navigation", request: .init(start: .timestamp(1700000005000)))
        // The librdkafka mock server does not model real timestamp indexing;
        // this exercises encoding, error handling and per-partition results.
        #expect(Set(offsets.keys) == [0, 1])
        #expect(offsets.values.allSatisfy { $0 >= 0 })
    }
}
