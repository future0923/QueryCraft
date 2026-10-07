import Foundation
import CRdkafka
import QueryCraftFeature

extension KafkaRdkafkaClient {
    func consumerGroups() throws -> [WorkspaceKafkaConsumerGroup] {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        return try withAdminEvent(operation: RD_KAFKA_ADMIN_OP_LISTCONSUMERGROUPS) { options, queue in
            rd_kafka_ListConsumerGroups(handle, options, queue)
        } decode: { event in
            guard let result = rd_kafka_event_ListConsumerGroups_result(event) else {
                throw KafkaError.network("Missing consumer groups result")
            }
            var errorCount = 0
            if let errors = rd_kafka_ListConsumerGroups_result_errors(result, &errorCount), errorCount > 0 {
                let messages = (0..<errorCount).compactMap { index in
                    errors[index].map { String(cString: rd_kafka_error_string($0)) }
                }
                throw KafkaError.network(messages.joined(separator: "; "))
            }
            var count = 0
            guard let groups = rd_kafka_ListConsumerGroups_result_valid(result, &count) else { return [] }
            return (0..<count).compactMap { index -> WorkspaceKafkaConsumerGroup? in
                guard let group = groups[index], let id = rd_kafka_ConsumerGroupListing_group_id(group) else { return nil }
                let state = rd_kafka_ConsumerGroupListing_state(group)
                return .init(id: String(cString: id), state: String(cString: rd_kafka_consumer_group_state_name(state)))
            }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        }
    }

    func consumerOffsets(groupID: String, topic: String) throws -> [WorkspaceKafkaConsumerOffset] {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard !groupID.isEmpty, !groupID.contains("\0"), !topic.isEmpty, !topic.contains("\0") else {
            throw KafkaError.invalidConfiguration("Consumer group and topic must not be empty or contain NUL")
        }
        let deadline = Date().addingTimeInterval(15)
        guard let topicMetadata = try metadata().topics.first(where: { $0.name == topic }) else {
            throw WorkspaceSessionError.metadataUnavailable(object: topic)
        }
        let committed = try committedOffsets(groupID: groupID, topic: topic,
                                             partitionIDs: topicMetadata.partitions.map(\.partition), deadline: deadline)
        return try topicMetadata.partitions.sorted { $0.partition < $1.partition }.map { partition in
            try Task.checkCancellation()
            let value = committed[partition.partition]
            var begin: Int64 = 0
            var end: Int64 = 0
            let remaining = min(3_000, Int32(max(0, deadline.timeIntervalSinceNow * 1_000)))
            let error = remaining > 0
                ? rd_kafka_query_watermark_offsets(handle, topic, partition.partition, &begin, &end, remaining)
                : RD_KAFKA_RESP_ERR__TIMED_OUT
            try Task.checkCancellation()
            let succeeded = error == RD_KAFKA_RESP_ERR_NO_ERROR
            return .init(partition: partition.partition, committedOffset: value?.offset,
                         beginningOffset: succeeded ? begin : nil, endOffset: succeeded ? end : nil,
                         error: value?.error ?? (succeeded ? nil : String(cString: rd_kafka_err2str(error))))
        }
    }

    func committedOffsets(groupID: String, topic: String, partitionIDs: [Int32], deadline: Date)
        throws -> [Int32: (offset: Int64?, error: String?)] {
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard !groupID.isEmpty, !groupID.contains("\0"), !topic.isEmpty, !topic.contains("\0") else {
            throw KafkaError.invalidConfiguration("Consumer group and topic must not be empty or contain NUL")
        }
        guard let partitions = rd_kafka_topic_partition_list_new(Int32(partitionIDs.count)) else {
            throw KafkaError.network("Could not allocate partitions")
        }
        defer { rd_kafka_topic_partition_list_destroy(partitions) }
        for partition in partitionIDs {
            guard rd_kafka_topic_partition_list_add(partitions, topic, partition) != nil else {
                throw KafkaError.network("Could not add partition")
            }
        }
        guard let request = rd_kafka_ListConsumerGroupOffsets_new(groupID, partitions) else {
            throw KafkaError.network("Could not allocate consumer offset request")
        }
        defer { rd_kafka_ListConsumerGroupOffsets_destroy(request) }
        return try withAdminEvent(
            operation: RD_KAFKA_ADMIN_OP_LISTCONSUMERGROUPOFFSETS, deadline: deadline
        ) { options, queue in
            var requests: [OpaquePointer?] = [request]
            requests.withUnsafeMutableBufferPointer {
                rd_kafka_ListConsumerGroupOffsets(handle, $0.baseAddress, 1, options, queue)
            }
        } decode: { event in
            guard let result = rd_kafka_event_ListConsumerGroupOffsets_result(event) else {
                throw KafkaError.network("Missing consumer offset result")
            }
            var count = 0
            guard let results = rd_kafka_ListConsumerGroupOffsets_result_groups(result, &count),
                  count == 1, let group = results[0] else {
                throw KafkaError.network("Missing consumer group result")
            }
            if let error = rd_kafka_group_result_error(group) {
                throw KafkaError.network(String(cString: rd_kafka_error_string(error)))
            }
            guard let list = rd_kafka_group_result_partitions(group) else { return [:] }
            var values: [Int32: (offset: Int64?, error: String?)] = [:]
            for index in 0..<Int(list.pointee.cnt) {
                let partition = list.pointee.elems[index]
                guard let name = partition.topic, String(cString: name) == topic else { continue }
                values[partition.partition] = (
                    partition.offset >= 0 ? partition.offset : nil,
                    partition.err == RD_KAFKA_RESP_ERR_NO_ERROR ? nil : String(cString: rd_kafka_err2str(partition.err))
                )
            }
            return values
        }
    }

    func withAdminEvent<T>(
        operation: rd_kafka_admin_op_t,
        deadline: Date = Date().addingTimeInterval(10),
        observesCancellationAfterSubmission: Bool = true,
        operationTimeoutMilliseconds: Int32? = nil,
        submit: (OpaquePointer, OpaquePointer) -> Void,
        decode: (OpaquePointer) throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard deadline > Date() else { throw KafkaError.network("Kafka admin request timed out") }
        guard let options = rd_kafka_AdminOptions_new(handle, operation) else {
            throw KafkaError.network("Could not allocate admin options")
        }
        defer { rd_kafka_AdminOptions_destroy(options) }
        guard let queue = rd_kafka_queue_new(handle) else {
            throw KafkaError.network("Could not allocate admin queue")
        }
        defer { rd_kafka_queue_destroy(queue) }
        var errorText = [CChar](repeating: 0, count: 512)
        let timeout = Int32(max(1, min(10_000, deadline.timeIntervalSinceNow * 1_000)))
        let error = rd_kafka_AdminOptions_set_request_timeout(options, timeout, &errorText, errorText.count)
        guard error == RD_KAFKA_RESP_ERR_NO_ERROR else {
            throw KafkaError.network(String(cString: rd_kafka_err2str(error)))
        }
        if let operationTimeoutMilliseconds {
            let operationError = rd_kafka_AdminOptions_set_operation_timeout(options, operationTimeoutMilliseconds, &errorText, errorText.count)
            guard operationError == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw KafkaError.network(String(cString: rd_kafka_err2str(operationError)))
            }
        }
        submit(options, queue)
        while Date() < deadline {
            if observesCancellationAfterSubmission { try Task.checkCancellation() }
            guard let event = rd_kafka_queue_poll(queue, 100) else { continue }
            defer { rd_kafka_event_destroy(event) }
            if observesCancellationAfterSubmission { try Task.checkCancellation() }
            guard rd_kafka_event_error(event) == RD_KAFKA_RESP_ERR_NO_ERROR else {
                throw KafkaError.network(String(cString: rd_kafka_event_error_string(event)))
            }
            return try decode(event)
        }
        throw KafkaError.network("Kafka admin request timed out")
    }
}
