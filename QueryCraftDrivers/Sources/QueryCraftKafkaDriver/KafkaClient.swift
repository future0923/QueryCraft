import QueryCraftFeature

/// Synchronous clients are created and used exclusively by the session actor.
protocol KafkaClient: AnyObject {
    func connect() throws
    func close()
    func isConnected() -> Bool
    func metadata() throws -> KafkaRdkafkaMetadata
    func consumerGroups() throws -> [WorkspaceKafkaConsumerGroup]
    func consumerGroupDetails(groupID: String, topic: String) throws -> WorkspaceKafkaConsumerGroupDetails
    func consumerOffsets(groupID: String, topic: String) throws -> [WorkspaceKafkaConsumerOffset]
    func topicDetails(topic: String) throws -> WorkspaceKafkaTopicDetails
    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) throws
    func groupTopicMembership(groupID: String, topic: String, partitions: [Int32]) throws -> WorkspaceKafkaGroupTopicMembership
    func createTopic(name: String, partitions: Int32, replicationFactor: Int16) throws
    func deleteTopic(name: String) throws
    func produce(_ request: WorkspaceKafkaProduceRequest) throws -> WorkspaceKafkaProduceReceipt
    func startingOffsets(topic: String, request: WorkspaceKafkaReadRequest) throws -> [Int32: Int64]
    func fetch(topic: String, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult
    func fetch(topic: String, offsets: [Int32: Int64], maximumMessages: Int) throws -> KafkaRdkafkaFetchResult
    func tailStartingOffsets(topic: String, partition: Int32?) throws -> [Int32: Int64]
    func pollTail(topic: String, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult
}

extension KafkaClient {
    func deleteTopic(name: String) throws {
        throw WorkspaceKafkaTopicDeletionError.driverUpdateRequired
    }
    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) throws {
        throw WorkspaceKafkaTopicConfigurationError.driverUpdateRequired
    }
    func produce(_ request: WorkspaceKafkaProduceRequest) throws -> WorkspaceKafkaProduceReceipt {
        throw WorkspaceKafkaProduceError.driverUpdateRequired
    }
    func tailStartingOffsets(topic: String, partition: Int32?) throws -> [Int32: Int64] {
        throw KafkaError.network("Live reading is unavailable")
    }
    func pollTail(topic: String, offsets: [Int32: Int64]) throws -> KafkaRdkafkaFetchResult {
        throw KafkaError.network("Live reading is unavailable")
    }
    func fetch(topic: String, offsets: [Int32: Int64], maximumMessages: Int) throws -> KafkaRdkafkaFetchResult {
        try fetch(topic: topic, offsets: offsets)
    }
}
