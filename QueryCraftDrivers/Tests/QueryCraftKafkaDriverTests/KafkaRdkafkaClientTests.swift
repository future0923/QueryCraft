import Foundation
import CRdkafka
import QueryCraftFeature
import Testing
@testable import QueryCraftKafkaDriver

@Suite("Kafka librdkafka client")
struct KafkaRdkafkaClientTests {
    @Test("Topic deletion rejects invalid or internal names before native dispatch")
    func invalidDeletionRequests() throws {
        let client = KafkaRdkafkaClient(configuration: try KafkaConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .kafka, host: "localhost", port: 9092, authentication: .none, database: nil, tlsMode: .disabled)))
        for name in ["", "events\0other", "events*", "__consumer_offsets"] {
            #expect(throws: WorkspaceKafkaTopicDeletionError.self) { try client.deleteTopic(name: name) }
        }
        #expect(throws: WorkspaceSessionError.self) { try client.deleteTopic(name: "events") }
    }

    @Test("Deletion distinguishes acknowledgement, rejection and uncertain timeout")
    func deletionResults() throws {
        try KafkaRdkafkaClient.validateTopicDeletionResult(error: RD_KAFKA_RESP_ERR_NO_ERROR, message: "")
        try KafkaRdkafkaClient.validateTopicDeletionResult(error: RD_KAFKA_RESP_ERR_UNKNOWN_TOPIC_OR_PART, message: "missing")
        for code in [RD_KAFKA_RESP_ERR_TOPIC_AUTHORIZATION_FAILED, RD_KAFKA_RESP_ERR_TOPIC_DELETION_DISABLED] {
            do {
                try KafkaRdkafkaClient.validateTopicDeletionResult(error: code, message: "rejected")
                Issue.record("Rejected deletion must not be reported as success")
            } catch WorkspaceKafkaTopicDeletionError.rejected {} catch { Issue.record("Incorrect rejection: \(error)") }
        }
        do {
            try KafkaRdkafkaClient.validateTopicDeletionResult(error: RD_KAFKA_RESP_ERR_REQUEST_TIMED_OUT, message: "timeout")
            Issue.record("Timeout must not be reported as success")
        } catch WorkspaceKafkaTopicDeletionError.unconfirmed {} catch { Issue.record("Incorrect timeout: \(error)") }
    }

    @Test("Consumer member requests reject invalid names before contacting the broker")
    func invalidConsumerMemberRequests() throws {
        let client = KafkaRdkafkaClient(configuration: try KafkaConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .kafka, host: "localhost", port: 9092, authentication: .none, database: nil, tlsMode: .disabled)))
        for (group, topic) in [("", "events"), ("group\0other", "events"), ("group", ""), ("group", "events\0other")] {
            #expect(throws: KafkaError.self) { try client.consumerGroupDetails(groupID: group, topic: topic) }
        }
        #expect(throws: WorkspaceSessionError.self) { try client.consumerGroupDetails(groupID: "group", topic: "events") }
    }

    @Test("Native configuration supports every SASL mechanism", arguments: KafkaSASLMechanism.allCases)
    func saslConfiguration(mechanism: KafkaSASLMechanism) throws {
        var configuration = try KafkaConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .kafka, host: "localhost", port: 1,
            authentication: .usernamePassword(username: "reader", password: "test-secret"),
            database: nil, tlsMode: .verifyIdentity))
        configuration.saslMechanism = mechanism
        let client = KafkaRdkafkaClient(configuration: configuration)
        try client.connect()
        defer { client.close() }
        let handle = try #require(client.handle)
        let conf = rd_kafka_conf(handle)
        for (key, expected) in ["sasl.mechanisms": mechanism.rawValue, "security.protocol": "sasl_ssl",
                                "enable.auto.commit": "false", "enable.auto.offset.store": "false"] {
            var length = 256
            var bytes = [CChar](repeating: 0, count: length)
            #expect(rd_kafka_conf_get(conf, key, &bytes, &length) == RD_KAFKA_CONF_OK)
            #expect(String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == expected)
        }
    }

    @Test("Lists consumer groups without changing broker state",
          .enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_GROUP_SMOKE"] != nil))
    func consumerGroupsSmoke() throws {
        let host = try #require(ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_GROUP_SMOKE"])
        let client = KafkaRdkafkaClient(configuration: try KafkaConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .kafka, host: host, port: 9092, authentication: .none, database: nil, tlsMode: .disabled)))
        try client.connect()
        defer { client.close() }
        let groups = try client.consumerGroups()
        #expect(groups.allSatisfy { !$0.id.isEmpty })
        let preferredGroup = ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_GROUP_SMOKE_GROUP"]
        if let group = groups.first(where: { $0.id == preferredGroup }) ?? groups.first,
           let topic = ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_GROUP_SMOKE_TOPIC"] {
            let offsets = try client.consumerOffsets(groupID: group.id, topic: topic)
            #expect(!offsets.isEmpty)
            #expect(offsets.allSatisfy { $0.error == nil })
            let details = try client.topicDetails(topic: topic)
            #expect(details.partitions.isEmpty == false)
            #expect(details.partitions.allSatisfy { !$0.replicas.isEmpty && $0.leader != nil })
            #expect(details.configurationError == nil)
            #expect(details.configurations.contains { $0.name == "cleanup.policy" })
            #expect(details.configurations.contains { $0.name == "retention.ms" })
            let membership = try client.groupTopicMembership(groupID: group.id, topic: topic, partitions: details.partitions.map(\.id))
            #expect(membership != .unknown)
            let groupDetails = try client.consumerGroupDetails(groupID: group.id, topic: topic)
            #expect(groupDetails.state.isEmpty == false)
            #expect(groupDetails.members.allSatisfy { !$0.id.isEmpty })
            #expect(groupDetails.members.flatMap(\.partitions).allSatisfy { partition in details.partitions.contains { $0.id == partition } })
        }
    }

    @Test("Reads metadata and messages from an opt-in broker",
          .enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_SMOKE_BOOTSTRAP"] != nil))
    func brokerSmokeTest() throws {
        guard let bootstrap = ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_SMOKE_BOOTSTRAP"] else {
            return
        }
        let parts = bootstrap.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = Int(parts[1]) else {
            Issue.record("QUERYCRAFT_KAFKA_SMOKE_BOOTSTRAP must be host:port")
            return
        }
        let configuration = try KafkaConnectionConfiguration(
            DatabaseConnectionConfiguration(
                databaseType: .kafka,
                databaseProduct: .kafka,
                host: parts[0],
                port: port,
                authentication: .none,
                database: nil,
                tlsMode: .disabled
            )
        )
        let client = KafkaRdkafkaClient(configuration: configuration)
        try client.connect()
        defer { client.close() }

        let metadata = try client.metadata()
        #expect(!metadata.brokers.isEmpty)
        #expect(!metadata.topics.isEmpty)

        guard let topic = metadata.topics.first,
              let partition = topic.partitions.first
        else { return }
        let fetched = try client.fetch(
            topic: topic.name,
            offsets: [partition.partition: 0]
        )
        #expect(fetched.messages.allSatisfy { $0.partition == partition.partition })
    }

    @Test("Reports an existing topic from the CreateTopics admin API",
          .enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_SMOKE_BOOTSTRAP"] != nil
                   && ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_CREATE_EXISTING_TOPIC"] == "1"))
    func existingTopicCreationSmokeTest() throws {
        guard let bootstrap = ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_SMOKE_BOOTSTRAP"],
              ProcessInfo.processInfo.environment["QUERYCRAFT_KAFKA_CREATE_EXISTING_TOPIC"] == "1"
        else {
            return
        }
        let parts = bootstrap.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let port = Int(parts[1]) else {
            Issue.record("QUERYCRAFT_KAFKA_SMOKE_BOOTSTRAP must be host:port")
            return
        }
        let configuration = try KafkaConnectionConfiguration(
            DatabaseConnectionConfiguration(
                databaseType: .kafka,
                databaseProduct: .kafka,
                host: parts[0],
                port: port,
                authentication: .none,
                database: nil,
                tlsMode: .disabled
            )
        )
        let client = KafkaRdkafkaClient(configuration: configuration)
        try client.connect()
        defer { client.close() }
        guard let topic = try client.metadata().topics.first,
              let partitionCount = Int32(exactly: topic.partitions.count),
              partitionCount > 0
        else {
            Issue.record("The smoke broker must expose at least one topic with partitions")
            return
        }

        do {
            try client.createTopic(
                name: topic.name,
                partitions: partitionCount,
                replicationFactor: 1
            )
            Issue.record("CreateTopics unexpectedly succeeded for an existing topic")
        } catch let KafkaError.network(message) {
            #expect(message.localizedCaseInsensitiveContains("exist"))
        }
    }
}
