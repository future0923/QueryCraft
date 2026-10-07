import Foundation
import CRdkafka
import QueryCraftFeature

extension KafkaRdkafkaClient {
    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) throws {
        try request.validate()
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard let resource = rd_kafka_ConfigResource_new(RD_KAFKA_RESOURCE_TOPIC, request.topic) else {
            throw KafkaError.network("Could not allocate topic configuration request")
        }
        defer { rd_kafka_ConfigResource_destroy(resource) }
        for change in request.changes {
            let operation = change.value == nil ? RD_KAFKA_ALTER_CONFIG_OP_TYPE_DELETE : RD_KAFKA_ALTER_CONFIG_OP_TYPE_SET
            if let error = rd_kafka_ConfigResource_add_incremental_config(resource, change.id, operation, change.value) {
                defer { rd_kafka_error_destroy(error) }
                throw KafkaError.invalidConfiguration(String(cString: rd_kafka_error_string(error)))
            }
        }
        // Once submitted, wait for the bounded broker result even if the UI closes.
        // Do not fall back to AlterConfigs: it would reset unmentioned overrides.
        try withAdminEvent(operation: RD_KAFKA_ADMIN_OP_INCREMENTALALTERCONFIGS,
                           observesCancellationAfterSubmission: false) { options, queue in
            var resources: [OpaquePointer?] = [resource]
            resources.withUnsafeMutableBufferPointer {
                rd_kafka_IncrementalAlterConfigs(handle, $0.baseAddress, 1, options, queue)
            }
        } decode: { event in
            guard let result = rd_kafka_event_IncrementalAlterConfigs_result(event) else {
                throw KafkaError.network("Missing topic configuration update result")
            }
            var count = 0
            guard let resources = rd_kafka_IncrementalAlterConfigs_result_resources(result, &count),
                  count == 1, let resource = resources[0] else {
                throw KafkaError.network("Missing topic configuration update resource")
            }
            let error = rd_kafka_ConfigResource_error(resource)
            guard error == RD_KAFKA_RESP_ERR_NO_ERROR else {
                let message = rd_kafka_ConfigResource_error_string(resource).map { String(cString: $0) }
                if [RD_KAFKA_RESP_ERR_INVALID_CONFIG, RD_KAFKA_RESP_ERR_INVALID_REQUEST,
                    RD_KAFKA_RESP_ERR_TOPIC_AUTHORIZATION_FAILED, RD_KAFKA_RESP_ERR_CLUSTER_AUTHORIZATION_FAILED,
                    RD_KAFKA_RESP_ERR_UNSUPPORTED_VERSION, RD_KAFKA_RESP_ERR_POLICY_VIOLATION].contains(error) {
                    throw WorkspaceKafkaTopicConfigurationError.rejected(message ?? String(cString: rd_kafka_err2str(error)))
                }
                throw KafkaError.network(message ?? String(cString: rd_kafka_err2str(error)))
            }
        }
    }

    func topicDetails(topic: String) throws -> WorkspaceKafkaTopicDetails {
        try Task.checkCancellation()
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard !topic.isEmpty, !topic.contains("\0") else { throw KafkaError.invalidConfiguration("Invalid topic name") }
        let deadline = Date().addingTimeInterval(10)
        var pointer: UnsafePointer<rd_kafka_metadata_t>?
        let error = rd_kafka_metadata(handle, 1, nil, &pointer, 5_000)
        guard error == RD_KAFKA_RESP_ERR_NO_ERROR, let metadata = pointer else {
            throw KafkaError.network(String(cString: rd_kafka_err2str(error)))
        }
        defer { rd_kafka_metadata_destroy(metadata) }
        try Task.checkCancellation()
        var partitions: [WorkspaceKafkaTopicPartition]?
        if let topics = metadata.pointee.topics {
            for index in 0..<Int(metadata.pointee.topic_cnt) {
                let item = topics[index]
                guard let name = item.topic, String(cString: name) == topic else { continue }
                guard item.err == RD_KAFKA_RESP_ERR_NO_ERROR else {
                    throw KafkaError.network(String(cString: rd_kafka_err2str(item.err)))
                }
                partitions = (0..<Int(item.partition_cnt)).map { index in
                    let p = item.partitions[index]
                    return .init(id: p.id, leader: p.leader < 0 ? nil : p.leader,
                                 replicas: p.replicas.map { Array(UnsafeBufferPointer(start: $0, count: Int(p.replica_cnt))) } ?? [],
                                 inSyncReplicas: p.isrs.map { Array(UnsafeBufferPointer(start: $0, count: Int(p.isr_cnt))) } ?? [],
                                 error: p.err == RD_KAFKA_RESP_ERR_NO_ERROR ? nil : String(cString: rd_kafka_err2str(p.err)))
                }.sorted { $0.id < $1.id }
                break
            }
        }
        guard let partitions else { throw WorkspaceSessionError.metadataUnavailable(object: topic) }
        do {
            let configs = try topicConfigurations(topic: topic, deadline: deadline)
            return .init(partitions: partitions, configurations: configs)
        } catch {
            try Task.checkCancellation()
            // DESCRIBE_CONFIGS is a separate ACL: preserve readable partition metadata.
            return .init(partitions: partitions, configurations: [], configurationError: error.localizedDescription)
        }
    }

    private func topicConfigurations(topic: String, deadline: Date) throws -> [WorkspaceKafkaTopicConfiguration] {
        guard let handle else { throw WorkspaceSessionError.notConnected }
        guard let resource = rd_kafka_ConfigResource_new(RD_KAFKA_RESOURCE_TOPIC, topic) else {
            throw KafkaError.network("Could not allocate topic configuration request")
        }
        defer { rd_kafka_ConfigResource_destroy(resource) }
        return try withAdminEvent(operation: RD_KAFKA_ADMIN_OP_DESCRIBECONFIGS, deadline: deadline) { options, queue in
            var resources: [OpaquePointer?] = [resource]
            resources.withUnsafeMutableBufferPointer { rd_kafka_DescribeConfigs(handle, $0.baseAddress, 1, options, queue) }
        } decode: { event in
            guard let result = rd_kafka_event_DescribeConfigs_result(event) else { throw KafkaError.network("Missing topic configuration result") }
            var count = 0
            guard let resources = rd_kafka_DescribeConfigs_result_resources(result, &count), count == 1,
                  let resource = resources[0] else { throw KafkaError.network("Missing topic configuration resource") }
            let error = rd_kafka_ConfigResource_error(resource)
            guard error == RD_KAFKA_RESP_ERR_NO_ERROR else { throw KafkaError.network(String(cString: rd_kafka_err2str(error))) }
            var entryCount = 0
            guard let entries = rd_kafka_ConfigResource_configs(resource, &entryCount) else { return [] }
            return (0..<entryCount).compactMap { index -> WorkspaceKafkaTopicConfiguration? in
                guard let entry = entries[index], let name = rd_kafka_ConfigEntry_name(entry) else { return nil }
                let sensitive = rd_kafka_ConfigEntry_is_sensitive(entry) == 1
                let source = rd_kafka_ConfigEntry_source(entry)
                return .init(name: String(cString: name),
                             value: sensitive ? nil : rd_kafka_ConfigEntry_value(entry).map { String(cString: $0) },
                             // Broker overrides are inherited too; only a topic source
                             // can be removed by a topic-level DELETE operation.
                             isDefault: source == RD_KAFKA_CONFIG_SOURCE_UNKNOWN_CONFIG
                                ? rd_kafka_ConfigEntry_is_default(entry) == 1
                                : source != RD_KAFKA_CONFIG_SOURCE_DYNAMIC_TOPIC_CONFIG,
                             isSensitive: sensitive, isReadOnly: rd_kafka_ConfigEntry_is_read_only(entry) != 0)
            }.sorted { $0.name < $1.name }
        }
    }

    func groupTopicMembership(groupID: String, topic: String, partitions: [Int32]) throws -> WorkspaceKafkaGroupTopicMembership {
        try Task.checkCancellation()
        guard !groupID.isEmpty, !groupID.contains("\0"), !topic.isEmpty, !topic.contains("\0") else {
            throw KafkaError.invalidConfiguration("Invalid consumer group or topic")
        }
        // A bounded call per group lets the UI interleave selected-group reads
        // instead of locking its session behind an entire cluster scan.
        let deadline = Date().addingTimeInterval(4)
        let assigned: Bool?
        do { assigned = try groupHasAssignment(groupID: groupID, topic: topic, deadline: Date().addingTimeInterval(2)) }
        catch { try Task.checkCancellation(); assigned = nil }
        if assigned == true { return .related }
        do {
            let commits = try committedOffsets(groupID: groupID, topic: topic, partitionIDs: partitions, deadline: deadline)
            if commits.values.contains(where: { $0.offset != nil && $0.error == nil }) { return .related }
            guard assigned == false, !partitions.isEmpty,
                  partitions.allSatisfy({ commits[$0] != nil && commits[$0]?.error == nil }) else { return .unknown }
            return .unrelated
        } catch { try Task.checkCancellation(); return .unknown }
    }

    private func groupHasAssignment(groupID: String, topic: String, deadline: Date) throws -> Bool {
        try consumerGroupDetails(groupID: groupID, topic: topic, deadline: deadline)
            .members.contains { !$0.partitions.isEmpty }
    }

    func consumerGroupDetails(groupID: String, topic: String) throws -> WorkspaceKafkaConsumerGroupDetails {
        try consumerGroupDetails(groupID: groupID, topic: topic, deadline: Date().addingTimeInterval(8))
    }

    private func consumerGroupDetails(groupID: String, topic: String, deadline: Date) throws -> WorkspaceKafkaConsumerGroupDetails {
        try Task.checkCancellation()
        guard !groupID.isEmpty, !groupID.contains("\0"), !topic.isEmpty, !topic.contains("\0") else {
            throw KafkaError.invalidConfiguration("Invalid consumer group or topic")
        }
        guard let handle else { throw WorkspaceSessionError.notConnected }
        return try withAdminEvent(operation: RD_KAFKA_ADMIN_OP_DESCRIBECONSUMERGROUPS, deadline: deadline) { options, queue in
            groupID.withCString { id in
                var ids: [UnsafePointer<CChar>?] = [id]
                ids.withUnsafeMutableBufferPointer { rd_kafka_DescribeConsumerGroups(handle, $0.baseAddress, 1, options, queue) }
            }
        } decode: { event in
            guard let result = rd_kafka_event_DescribeConsumerGroups_result(event) else { throw KafkaError.network("Missing group description") }
            var count = 0
            guard let groups = rd_kafka_DescribeConsumerGroups_result_groups(result, &count), count == 1,
                  let group = groups[0] else { throw KafkaError.network("Missing group") }
            if let error = rd_kafka_ConsumerGroupDescription_error(group) { throw KafkaError.network(String(cString: rd_kafka_error_string(error))) }
            var members: [WorkspaceKafkaConsumerMember] = []
            for index in 0..<rd_kafka_ConsumerGroupDescription_member_count(group) {
                guard let member = rd_kafka_ConsumerGroupDescription_member(group, index),
                      let id = rd_kafka_MemberDescription_consumer_id(member) else {
                    throw KafkaError.network("Missing consumer member identity")
                }
                var partitions: [Int32] = []
                if let assignment = rd_kafka_MemberDescription_assignment(member),
                   let list = rd_kafka_MemberAssignment_partitions(assignment) {
                    for index in 0..<Int(list.pointee.cnt) {
                        let item = list.pointee.elems[index]
                        if let name = item.topic, String(cString: name) == topic { partitions.append(item.partition) }
                    }
                }
                members.append(.init(id: String(cString: id),
                    clientID: rd_kafka_MemberDescription_client_id(member).map { String(cString: $0) } ?? "",
                    host: rd_kafka_MemberDescription_host(member).map { String(cString: $0) } ?? "",
                    instanceID: rd_kafka_MemberDescription_group_instance_id(member).map { String(cString: $0) },
                    partitions: partitions.sorted()))
            }
            return .init(state: String(cString: rd_kafka_consumer_group_state_name(rd_kafka_ConsumerGroupDescription_state(group))),
                         assignor: rd_kafka_ConsumerGroupDescription_partition_assignor(group).map { String(cString: $0) } ?? "",
                         members: members.sorted { $0.id < $1.id })
        }
    }
}
