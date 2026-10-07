import Foundation
import CRdkafka
import QueryCraftFeature

struct KafkaRdkafkaMetadata: Sendable {
    let brokers: [Int32: KafkaBrokerAddress]
    let topics: [KafkaTopicMetadata]
}

struct KafkaRdkafkaPartitionStats: Sendable {
    let partition: Int32
    let leader: Int32
    let replicas: [Int32]
    let isr: [Int32]
    let beginOffset: Int64
    let endOffset: Int64
}

struct KafkaRdkafkaFetchResult: Sendable {
    let messages: [KafkaMessage]
    let nextOffsets: [Int32: Int64]
    let exhausted: Set<Int32>
}

/// Thin, synchronous wrapper around librdkafka.
///
/// The workspace session owns this object from its actor, so all librdkafka
/// calls are serialized by the session. librdkafka itself owns broker
/// connections, protocol version negotiation, compression and authentication.
final class KafkaRdkafkaClient: KafkaClient {
    private static let defaultTimeoutMilliseconds: Int32 = 10_000
    private static let fetchPollMilliseconds: Int32 = 100
    private static let fetchWindowMilliseconds = 1_000
    private static let maximumMessagesPerFetch = 1_000
    private static let adminTimeoutMilliseconds: Int32 = 10_000

    private let configuration: KafkaConnectionConfiguration
    private(set) var handle: OpaquePointer?
    private var tailTopic: String?
    private var tailOffsets: [Int32: Int64] = [:]
    private var tailHealthCheck = ContinuousClock.now

    init(configuration: KafkaConnectionConfiguration) {
        self.configuration = configuration
    }

    deinit {
        close()
    }

    func connect() throws {
        try Task.checkCancellation()
        guard handle == nil else { return }
        guard let conf = rd_kafka_conf_new() else {
            throw KafkaError.network("librdkafka could not create a configuration")
        }

        do {
            try configure(conf)
            var errorBuffer = [CChar](repeating: 0, count: 512)
            let nextHandle = rd_kafka_new(
                RD_KAFKA_CONSUMER,
                conf,
                &errorBuffer,
                errorBuffer.count
            )
            guard let nextHandle else {
                throw KafkaError.network(
                    "librdkafka could not create a consumer: "
                        + Self.string(from: errorBuffer)
                )
            }
            handle = nextHandle
        } catch {
            // rd_kafka_new consumes the configuration on success only.
            rd_kafka_conf_destroy(conf)
            throw error
        }
    }

    func close() {
        guard let handle else { return }
        // This driver never commits offsets or joins a subscription group.
        // Avoid the synchronous consumer_close handshake, which can wait
        // indefinitely when a broker is reachable but does not complete the
        // group leave request.
        rd_kafka_destroy_flags(handle, RD_KAFKA_DESTROY_F_NO_CONSUMER_CLOSE)
        self.handle = nil
        tailTopic = nil
        tailOffsets = [:]
    }

    func isConnected() -> Bool {
        handle != nil
    }

    func metadata() throws -> KafkaRdkafkaMetadata {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }

        var metadataPointer: UnsafePointer<rd_kafka_metadata_t>?
        let result = rd_kafka_metadata(
            handle,
            1,
            nil,
            &metadataPointer,
            Self.defaultTimeoutMilliseconds
        )
        guard result == RD_KAFKA_RESP_ERR_NO_ERROR,
              let metadata = metadataPointer
        else {
            throw Self.kafkaError(result, context: "metadata")
        }
        defer { rd_kafka_metadata_destroy(metadata) }
        try Task.checkCancellation()

        var brokers: [Int32: KafkaBrokerAddress] = [:]
        if metadata.pointee.broker_cnt > 0, let brokerPointer = metadata.pointee.brokers {
            for index in 0..<Int(metadata.pointee.broker_cnt) {
                let broker = brokerPointer[index]
                guard let host = broker.host else { continue }
                brokers[broker.id] = KafkaBrokerAddress(
                    host: String(cString: host),
                    port: Int(broker.port)
                )
            }
        }

        var topics: [KafkaTopicMetadata] = []
        if metadata.pointee.topic_cnt > 0, let topicPointer = metadata.pointee.topics {
            topics.reserveCapacity(Int(metadata.pointee.topic_cnt))
            for index in 0..<Int(metadata.pointee.topic_cnt) {
                let topic = topicPointer[index]
                guard let namePointer = topic.topic else { continue }
                let name = String(cString: namePointer)
                if topic.err != RD_KAFKA_RESP_ERR_NO_ERROR {
                    throw Self.kafkaError(topic.err, context: "topic " + name)
                }

                var partitions: [KafkaPartitionMetadata] = []
                if topic.partition_cnt > 0, let partitionPointer = topic.partitions {
                    partitions.reserveCapacity(Int(topic.partition_cnt))
                    for partitionIndex in 0..<Int(topic.partition_cnt) {
                        let partition = partitionPointer[partitionIndex]
                        guard partition.err == RD_KAFKA_RESP_ERR_NO_ERROR else {
                            throw Self.kafkaError(
                                partition.err,
                                context: "topic " + name + " partition " + String(partition.id)
                            )
                        }
                        partitions.append(
                            KafkaPartitionMetadata(
                                partition: partition.id,
                                leader: partition.leader
                            )
                        )
                    }
                }
                topics.append(KafkaTopicMetadata(name: name, partitions: partitions))
            }
        }

        return KafkaRdkafkaMetadata(brokers: brokers, topics: topics)
    }

    func createTopic(
        name: String,
        partitions: Int32,
        replicationFactor: Int16
    ) throws {
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard !name.isEmpty, partitions > 0, replicationFactor > 0 else {
            throw KafkaError.network("Topic name, partitions, and replication factor must be valid")
        }

        var errorBuffer = [CChar](repeating: 0, count: 512)
        guard let newTopic = name.withCString({ topicPointer in
            rd_kafka_NewTopic_new(
                topicPointer,
                partitions,
                Int32(replicationFactor),
                &errorBuffer,
                errorBuffer.count
            )
        }) else {
            throw KafkaError.network(Self.string(from: errorBuffer))
        }
        defer { rd_kafka_NewTopic_destroy(newTopic) }

        guard let options = rd_kafka_AdminOptions_new(
            handle,
            RD_KAFKA_ADMIN_OP_CREATETOPICS
        ) else {
            throw KafkaError.network("librdkafka could not create AdminOptions")
        }
        defer { rd_kafka_AdminOptions_destroy(options) }

        var adminErrorBuffer = [CChar](repeating: 0, count: 512)
        let requestResult = rd_kafka_AdminOptions_set_request_timeout(
            options,
            Self.adminTimeoutMilliseconds,
            &adminErrorBuffer,
            adminErrorBuffer.count
        )
        guard requestResult == RD_KAFKA_RESP_ERR_NO_ERROR else {
            throw Self.kafkaError(requestResult, context: Self.string(from: adminErrorBuffer))
        }
        let operationResult = rd_kafka_AdminOptions_set_operation_timeout(
            options,
            Self.adminTimeoutMilliseconds,
            &adminErrorBuffer,
            adminErrorBuffer.count
        )
        guard operationResult == RD_KAFKA_RESP_ERR_NO_ERROR else {
            throw Self.kafkaError(operationResult, context: Self.string(from: adminErrorBuffer))
        }

        guard let queue = rd_kafka_queue_new(handle) else {
            throw KafkaError.network("librdkafka could not create an admin queue")
        }
        defer { rd_kafka_queue_destroy(queue) }

        var newTopics: [OpaquePointer?] = [newTopic]
        newTopics.withUnsafeMutableBufferPointer { buffer in
            rd_kafka_CreateTopics(
                handle,
                buffer.baseAddress,
                buffer.count,
                options,
                queue
            )
        }

        guard let event = rd_kafka_queue_poll(queue, Self.adminTimeoutMilliseconds) else {
            throw KafkaError.network("Timed out while creating topic " + name)
        }
        defer { rd_kafka_event_destroy(event) }

        let eventError = rd_kafka_event_error(event)
        guard eventError == RD_KAFKA_RESP_ERR_NO_ERROR else {
            throw Self.kafkaError(
                eventError,
                context: String(cString: rd_kafka_event_error_string(event))
            )
        }
        guard let result = rd_kafka_event_CreateTopics_result(event) else {
            throw KafkaError.network("Kafka returned an invalid CreateTopics result")
        }

        var resultCount = 0
        guard let resultTopics = rd_kafka_CreateTopics_result_topics(result, &resultCount),
              resultCount > 0
        else {
            throw KafkaError.network("Kafka returned no CreateTopics result")
        }
        for index in 0..<resultCount {
            guard let topicResult = resultTopics[index] else { continue }
            let topicError = rd_kafka_topic_result_error(topicResult)
            guard topicError == RD_KAFKA_RESP_ERR_NO_ERROR else {
                let topicName = rd_kafka_topic_result_name(topicResult)
                    .map(String.init(cString:)) ?? name
                let topicMessage = rd_kafka_topic_result_error_string(topicResult)
                    .map(String.init(cString:)) ?? String(cString: rd_kafka_err2str(topicError))
                throw KafkaError.network(
                    "Unable to create topic " + topicName + ": " + topicMessage
                )
            }
        }
    }

    func partitionStats(topic name: String) throws -> [KafkaRdkafkaPartitionStats] {
        guard let handle else { throw WorkspaceSessionError.notConnected }
        let metadata = try metadata()
        guard let topic = metadata.topics.first(where: { $0.name == name }) else {
            throw KafkaError.network("Kafka topic does not exist: " + name)
        }

        return try topic.partitions.map { partition in
            var begin: Int64 = 0
            var end: Int64 = 0
            let result = name.withCString { topicPointer in
                rd_kafka_query_watermark_offsets(
                    handle,
                    topicPointer,
                    partition.partition,
                    &begin,
                    &end,
                    Self.defaultTimeoutMilliseconds
                )
            }
            guard result == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw Self.kafkaError(
                    result,
                    context: "watermarks for " + name + " partition " + String(partition.partition)
                )
            }
            return KafkaRdkafkaPartitionStats(
                partition: partition.partition,
                leader: partition.leader,
                replicas: [],
                isr: [],
                beginOffset: begin,
                endOffset: end
            )
        }
    }

    func startingOffsets(
        topic name: String,
        request: WorkspaceKafkaReadRequest
    ) throws -> [Int32: Int64] {
        try Task.checkCancellation()
        guard request.isValid else { throw WorkspaceSessionError.invalidPageRequest }
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard let topic = try metadata().topics.first(where: { $0.name == name }) else {
            throw WorkspaceSessionError.metadataUnavailable(object: name)
        }
        let partitions = topic.partitions.filter {
            request.partition == nil || request.partition == $0.partition
        }
        guard !partitions.isEmpty else { throw WorkspaceSessionError.invalidPageRequest }
        if case .earliest = request.start {
            return Dictionary(uniqueKeysWithValues: partitions.map { ($0.partition, Int64(0)) })
        }
        if case .offset(let offset) = request.start {
            return Dictionary(uniqueKeysWithValues: partitions.map { ($0.partition, offset) })
        }

        // Share one deadline across partitions, rather than waiting 10 seconds per partition.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var ends: [Int32: Int64] = [:]
        var starts: [Int32: Int64] = [:]
        for partition in partitions {
            var begin: Int64 = 0
            var end: Int64 = 0
            let result = try name.withCString { pointer in
                rd_kafka_query_watermark_offsets(
                    handle, pointer, partition.partition, &begin, &end,
                    try Self.remainingMilliseconds(until: deadline)
                )
            }
            guard result == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw Self.kafkaError(result, context: "seek topic " + name)
            }
            ends[partition.partition] = end
            if case .latest(let count) = request.start {
                starts[partition.partition] = max(begin, end - Int64(count))
            }
        }
        guard case .timestamp(let timestamp) = request.start else { return starts }
        guard let list = rd_kafka_topic_partition_list_new(Int32(partitions.count)) else {
            throw KafkaError.network("librdkafka could not create a timestamp request")
        }
        defer { rd_kafka_topic_partition_list_destroy(list) }
        for partition in partitions {
            guard let item = name.withCString({ rd_kafka_topic_partition_list_add(list, $0, partition.partition) }) else {
                throw KafkaError.network("librdkafka could not add a timestamp partition")
            }
            item.pointee.offset = timestamp
        }
        let result = rd_kafka_offsets_for_times(handle, list, try Self.remainingMilliseconds(until: deadline))
        guard result == RD_KAFKA_RESP_ERR_NO_ERROR else {
            throw Self.kafkaError(result, context: "timestamp lookup for " + name)
        }
        for index in 0..<Int(list.pointee.cnt) {
            let item = list.pointee.elems[index]
            guard item.err == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw Self.kafkaError(item.err, context: "timestamp lookup for " + name)
            }
            // -1 means no record at/after the timestamp; start at the current end.
            starts[item.partition] = item.offset < 0 ? ends[item.partition] : item.offset
        }
        try Task.checkCancellation()
        return starts
    }

    private static func remainingMilliseconds(until deadline: ContinuousClock.Instant) throws -> Int32 {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw KafkaError.network("Kafka request timed out") }
        let components = remaining.components
        return Int32(max(1, min(10_000, components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)))
    }

    func fetch(
        topic name: String,
        offsets: [Int32: Int64]
    ) throws -> KafkaRdkafkaFetchResult {
        try fetch(topic: name, offsets: offsets, maximumMessages: Self.maximumMessagesPerFetch)
    }

    func fetch(
        topic name: String,
        offsets: [Int32: Int64],
        maximumMessages: Int
    ) throws -> KafkaRdkafkaFetchResult {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard !offsets.isEmpty else {
            return KafkaRdkafkaFetchResult(messages: [], nextOffsets: [:], exhausted: [])
        }

        var watermarks: [Int32: (begin: Int64, end: Int64)] = [:]
        var activeOffsets: [Int32: Int64] = [:]
        var exhausted: Set<Int32> = []
        let requestDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        for (partition, offset) in offsets {
            try Task.checkCancellation()
            var begin: Int64 = 0
            var end: Int64 = 0
            let result = try name.withCString { topicPointer in
                rd_kafka_query_watermark_offsets(
                    handle,
                    topicPointer,
                    partition,
                    &begin,
                    &end,
                    try Self.remainingMilliseconds(until: requestDeadline)
                )
            }
            guard result == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw Self.kafkaError(
                    result,
                    context: "watermarks for " + name + " partition " + String(partition)
                )
            }
            watermarks[partition] = (begin, end)
            if end <= max(offset, begin) {
                exhausted.insert(partition)
            } else {
                activeOffsets[partition] = max(offset, begin)
            }
        }

        guard !activeOffsets.isEmpty else {
            return KafkaRdkafkaFetchResult(messages: [], nextOffsets: offsets, exhausted: exhausted)
        }

        guard let assignment = rd_kafka_topic_partition_list_new(Int32(activeOffsets.count)) else {
            throw KafkaError.network("librdkafka could not create a partition assignment")
        }
        defer { rd_kafka_topic_partition_list_destroy(assignment) }
        for (partition, offset) in activeOffsets {
            guard let item = name.withCString({ topicPointer in
                rd_kafka_topic_partition_list_add(assignment, topicPointer, partition)
            }) else {
                throw KafkaError.network(
                    "librdkafka could not add partition " + String(partition)
                )
            }
            item.pointee.offset = offset
        }

        let assignmentResult = rd_kafka_assign(handle, assignment)
        guard assignmentResult == RD_KAFKA_RESP_ERR_NO_ERROR else {
            throw Self.kafkaError(assignmentResult, context: "assign topic " + name)
        }

        var messages: [KafkaMessage] = []
        var nextOffsets = offsets
        var pending = Set(activeOffsets.keys)
        var deadline = requestDeadline

        while !pending.isEmpty,
              messages.count < min(Self.maximumMessagesPerFetch, max(1, maximumMessages)),
              ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard let message = rd_kafka_consumer_poll(handle, Self.fetchPollMilliseconds) else {
                continue
            }
            defer { rd_kafka_message_destroy(message) }

            let partition = message.pointee.partition
            if message.pointee.err != RD_KAFKA_RESP_ERR_NO_ERROR {
                if message.pointee.err == RD_KAFKA_RESP_ERR__PARTITION_EOF {
                    pending.remove(partition)
                    exhausted.insert(partition)
                    continue
                }
                throw Self.kafkaError(
                    message.pointee.err,
                    context: "poll topic " + name + " partition " + String(partition)
                )
            }

            if messages.isEmpty {
                deadline = min(requestDeadline, ContinuousClock.now.advanced(by: .milliseconds(Self.fetchWindowMilliseconds)))
            }
            messages.append(Self.message(from: message))
            let next = message.pointee.offset == Int64.max
                ? message.pointee.offset
                : message.pointee.offset + 1
            nextOffsets[partition] = next
            if let end = watermarks[partition]?.end, next >= end {
                pending.remove(partition)
            }
        }

        try Task.checkCancellation()
        if messages.isEmpty, !pending.isEmpty {
            throw KafkaError.network("Timed out waiting for Kafka messages")
        }
        for (partition, watermark) in watermarks where watermark.end <= nextOffsets[partition, default: 0] {
            exhausted.insert(partition)
        }
        return KafkaRdkafkaFetchResult(
            messages: messages,
            nextOffsets: nextOffsets,
            exhausted: exhausted
        )
    }

    func tailStartingOffsets(topic name: String, partition: Int32?) throws -> [Int32: Int64] {
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard let topic = try metadata().topics.first(where: { $0.name == name }) else {
            throw WorkspaceSessionError.metadataUnavailable(object: name)
        }
        let partitions = topic.partitions.filter { partition == nil || $0.partition == partition }
        guard !partitions.isEmpty else { throw WorkspaceSessionError.invalidPageRequest }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var offsets: [Int32: Int64] = [:]
        for partition in partitions {
            var begin: Int64 = 0, end: Int64 = 0
            let result = try name.withCString {
                rd_kafka_query_watermark_offsets(handle, $0, partition.partition, &begin, &end,
                                               try Self.remainingMilliseconds(until: deadline))
            }
            guard result == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(result, context: "live start " + name) }
            offsets[partition.partition] = end
        }
        return offsets
    }

    func pollTail(topic name: String, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard !offsets.isEmpty else { throw WorkspaceSessionError.invalidPageRequest }
        if tailTopic != name || tailOffsets != offsets {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            guard let assignment = rd_kafka_topic_partition_list_new(Int32(offsets.count)) else {
                throw KafkaError.network("Unable to create live assignment")
            }
            defer { rd_kafka_topic_partition_list_destroy(assignment) }
            for (partition, offset) in offsets {
                var begin: Int64 = 0, end: Int64 = 0
                let result = try name.withCString {
                    rd_kafka_query_watermark_offsets(handle, $0, partition, &begin, &end,
                                                   try Self.remainingMilliseconds(until: deadline))
                }
                guard result == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(result, context: "live resume " + name) }
                guard offset >= begin, offset <= end else {
                    throw KafkaError.network("Live position is outside the retained log. Start a new live read from the current end.")
                }
                guard let item = name.withCString({ rd_kafka_topic_partition_list_add(assignment, $0, partition) }) else {
                    throw KafkaError.network("Unable to add live partition")
                }
                item.pointee.offset = offset
            }
            let result = rd_kafka_assign(handle, assignment)
            guard result == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(result, context: "live assignment") }
            tailTopic = name
            tailOffsets = offsets
            tailHealthCheck = .now
        }
        // An idle topic is normal. A bounded metadata probe distinguishes it
        // from a silent disconnect, even when no consumer error is queued.
        if tailHealthCheck.duration(to: .now) >= .seconds(10) {
            var metadata: UnsafePointer<rd_kafka_metadata_t>?
            let result = rd_kafka_metadata(handle, 0, nil, &metadata, 2_000)
            if let metadata { rd_kafka_metadata_destroy(metadata) }
            guard result == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(result, context: "live connection") }
            tailHealthCheck = .now
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        var messages: [KafkaMessage] = []
        var nextOffsets = offsets
        var bytes = 0
        while ContinuousClock.now < deadline, messages.count < 1_000, bytes < 4 * 1_024 * 1_024 {
            try Task.checkCancellation()
            guard let native = rd_kafka_consumer_poll(handle, 100) else { continue }
            defer { rd_kafka_message_destroy(native) }
            let error = native.pointee.err
            if error == RD_KAFKA_RESP_ERR__PARTITION_EOF { continue }
            guard error == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(error, context: "live read " + name) }
            let message = Self.message(from: native)
            guard let offset = nextOffsets[message.partition], message.offset >= offset else { continue }
            guard message.offset < Int64.max else { throw KafkaError.network("Kafka offset overflow") }
            bytes += message.key?.count ?? 0
            bytes += message.value?.count ?? 0
            messages.append(message)
            nextOffsets[message.partition] = message.offset + 1
        }
        try Task.checkCancellation()
        tailOffsets = nextOffsets
        return .init(messages: messages, nextOffsets: nextOffsets, exhausted: [])
    }

    private func configure(_ conf: OpaquePointer, producer: Bool = false) throws {
        let bootstrapServers = configuration.bootstrapServers
            .map { address in
                let host = address.host.contains(":") ? "[" + address.host + "]" : address.host
                return host + ":" + String(address.port)
            }
            .joined(separator: ",")
        try set(conf, key: "bootstrap.servers", value: bootstrapServers)
        try set(conf, key: "client.id", value: "QueryCraft")
        if !producer {
            try set(conf, key: "group.id", value: "querycraft-viewer-" + UUID().uuidString)
            try set(conf, key: "enable.auto.commit", value: "false")
            try set(conf, key: "enable.auto.offset.store", value: "false")
            try set(conf, key: "enable.partition.eof", value: "true")
            // All reads assign explicit, watermark-checked positions. An expired
            // cursor must be reported rather than silently skipping retained data.
            try set(conf, key: "auto.offset.reset", value: "error")
            try set(conf, key: "queued.max.messages.kbytes", value: "32768")
            try set(conf, key: "fetch.min.bytes", value: "1")
            try set(conf, key: "fetch.wait.max.ms", value: "100")
            try set(conf, key: "max.partition.fetch.bytes", value: "1048576")
        }

        let hasCredentials = configuration.username != nil
        let securityProtocol: String
        switch (configuration.tlsMode, hasCredentials) {
        case (.disabled, false): securityProtocol = "PLAINTEXT"
        case (.disabled, true): securityProtocol = "SASL_PLAINTEXT"
        case (.required, false), (.verifyCA, false), (.verifyIdentity, false): securityProtocol = "SSL"
        case (.required, true), (.verifyCA, true), (.verifyIdentity, true): securityProtocol = "SASL_SSL"
        }
        try set(conf, key: "security.protocol", value: securityProtocol)

        if let username = configuration.username {
            try set(conf, key: "sasl.mechanisms", value: configuration.saslMechanism.rawValue)
            try set(conf, key: "sasl.username", value: username)
            try set(conf, key: "sasl.password", value: configuration.password ?? "")
        }

        switch configuration.tlsMode {
        case .disabled:
            break
        case .required:
            try set(conf, key: "enable.ssl.certificate.verification", value: "false")
            try set(conf, key: "ssl.endpoint.identification.algorithm", value: "")
        case .verifyCA:
            try set(conf, key: "enable.ssl.certificate.verification", value: "true")
            try set(conf, key: "ssl.endpoint.identification.algorithm", value: "")
        case .verifyIdentity:
            try set(conf, key: "enable.ssl.certificate.verification", value: "true")
            try set(conf, key: "ssl.endpoint.identification.algorithm", value: "https")
        }
    }

    func produce(_ request: WorkspaceKafkaProduceRequest) throws -> WorkspaceKafkaProduceReceipt {
        try request.validate()
        try Task.checkCancellation()
        guard handle != nil else { throw WorkspaceSessionError.notConnected }
        guard let topic = try metadata().topics.first(where: { $0.name == request.topic }) else {
            throw WorkspaceKafkaProduceError.invalidTopic
        }
        if let partition = request.partition, !topic.partitions.contains(where: { $0.partition == partition }) {
            throw WorkspaceKafkaProduceError.invalidPartition
        }
        guard let conf = rd_kafka_conf_new() else { throw KafkaError.network("Cannot create producer configuration") }
        let producer: OpaquePointer
        do {
            try configure(conf, producer: true)
            try set(conf, key: "enable.idempotence", value: "true")
            try set(conf, key: "acks", value: "all")
            try set(conf, key: "message.timeout.ms", value: "10000")
            try set(conf, key: "request.timeout.ms", value: "5000")
            try set(conf, key: "message.max.bytes", value: "2097152")
            rd_kafka_conf_set_events(conf, RD_KAFKA_EVENT_DR)
            var errorBuffer = [CChar](repeating: 0, count: 512)
            guard let result = rd_kafka_new(RD_KAFKA_PRODUCER, conf, &errorBuffer, errorBuffer.count) else {
                throw KafkaError.network(Self.string(from: errorBuffer))
            }
            producer = result
        } catch {
            rd_kafka_conf_destroy(conf)
            throw error
        }
        defer { rd_kafka_destroy(producer) }
        guard let queue = rd_kafka_queue_get_main(producer) else { throw KafkaError.network("Cannot create delivery queue") }
        defer { rd_kafka_queue_destroy(queue) }
        guard let headers = rd_kafka_headers_new(request.headers.count) else { throw KafkaError.network("Cannot create headers") }
        var enqueued = false
        defer { if !enqueued { rd_kafka_headers_destroy(headers) } }
        for header in request.headers {
            // A non-null buffer preserves empty values distinctly from null values.
            let bytes = Array(header.value ?? Data()) + [UInt8(0)]
            let error = bytes.withUnsafeBytes { buffer in
                header.name.withCString { name in
                    rd_kafka_header_add(headers, name, -1,
                        header.value == nil ? nil : buffer.baseAddress, header.value?.count ?? 0)
                }
            }
            guard error == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(error, context: "header") }
        }
        try Task.checkCancellation()
        let keyBytes = Array(request.key ?? Data()) + [UInt8(0)]
        let valueBytes = Array(request.value) + [UInt8(0)]
        let error = request.topic.withCString { name in
            keyBytes.withUnsafeBytes { key in
                valueBytes.withUnsafeBytes { value in
                    qc_kafka_produce(producer, name, request.partition ?? RD_KAFKA_PARTITION_UA,
                        request.key == nil ? nil : key.baseAddress, request.key?.count ?? 0,
                        request.isNullValue ? nil : value.baseAddress, request.value.count, headers)
                }
            }
        }
        guard error == RD_KAFKA_RESP_ERR_NO_ERROR else { throw Self.kafkaError(error, context: "produce") }
        enqueued = true
        // After enqueue, wait for a definitive delivery report even if cancelled.
        // No UI-level retries: an unacknowledged write may already be persisted.
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            guard let event = rd_kafka_queue_poll(queue, 100) else { continue }
            defer { rd_kafka_event_destroy(event) }
            guard rd_kafka_event_type(event) == RD_KAFKA_EVENT_DR,
                  let message = rd_kafka_event_message_next(event) else { continue }
            guard message.pointee.err == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw WorkspaceKafkaProduceError.deliveryUnconfirmed(String(cString: rd_kafka_err2str(message.pointee.err)))
            }
            return .init(partition: message.pointee.partition,
                         offset: message.pointee.offset >= 0 ? message.pointee.offset : nil)
        }
        rd_kafka_purge(producer, RD_KAFKA_PURGE_F_QUEUE | RD_KAFKA_PURGE_F_INFLIGHT | RD_KAFKA_PURGE_F_NON_BLOCKING)
        throw WorkspaceKafkaProduceError.deliveryUnconfirmed("delivery timeout")
    }

    private func set(_ conf: OpaquePointer, key: String, value: String) throws {
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = key.withCString { keyPointer in
            value.withCString { valuePointer in
                rd_kafka_conf_set(
                    conf,
                    keyPointer,
                    valuePointer,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }
        guard result == RD_KAFKA_CONF_OK else {
            throw KafkaError.invalidConfiguration(
                key + ": " + Self.string(from: errorBuffer)
            )
        }
    }

    private static func message(from message: UnsafeMutablePointer<rd_kafka_message_t>) -> KafkaMessage {
        let payload = data(pointer: message.pointee.payload, count: message.pointee.len)
        let key = data(pointer: message.pointee.key, count: message.pointee.key_len)
        let timestampValue = rd_kafka_message_timestamp(message, nil)
        let timestamp = timestampValue >= 0 ? timestampValue : nil
        return KafkaMessage(
            partition: message.pointee.partition,
            offset: message.pointee.offset,
            timestamp: timestamp,
            key: key,
            value: payload,
            headers: headers(from: message)
        )
    }

    private static func headers(from message: UnsafeMutablePointer<rd_kafka_message_t>) -> [KafkaHeader] {
        var headersPointer: OpaquePointer?
        guard rd_kafka_message_headers(message, &headersPointer) == RD_KAFKA_RESP_ERR_NO_ERROR,
              let headersPointer
        else { return [] }

        let count = rd_kafka_header_cnt(headersPointer)
        var headers: [KafkaHeader] = []
        headers.reserveCapacity(Int(count))
        for index in 0..<count {
            var name: UnsafePointer<CChar>?
            var value: UnsafeRawPointer?
            var size: Int = 0
            guard rd_kafka_header_get_all(
                headersPointer,
                index,
                &name,
                &value,
                &size
            ) == RD_KAFKA_RESP_ERR_NO_ERROR,
                  let name
            else { continue }
            headers.append(
                KafkaHeader(
                    key: String(cString: name),
                    value: value.map { Data(bytes: $0, count: size) }
                )
            )
        }
        return headers
    }

    private static func data(pointer: UnsafeMutableRawPointer?, count: Int) -> Data? {
        guard let pointer else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func kafkaError(
        _ code: rd_kafka_resp_err_t,
        context: String
    ) -> KafkaError {
        let description = String(cString: rd_kafka_err2str(code))
        return KafkaError.network(context + ": " + description)
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
