import Foundation

public struct WorkspaceKafkaConsumerGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let state: String

    public init(id: String, state: String) {
        self.id = id
        self.state = state
    }
}

public struct WorkspaceKafkaConsumerOffset: Equatable, Identifiable, Sendable {
    public let partition: Int32
    public let committedOffset: Int64?
    public let beginningOffset: Int64?
    public let endOffset: Int64?
    public let error: String?
    public var id: Int32 { partition }

    public init(partition: Int32, committedOffset: Int64?, beginningOffset: Int64?,
                endOffset: Int64?, error: String? = nil) {
        self.partition = partition
        self.committedOffset = committedOffset
        self.beginningOffset = beginningOffset
        self.endOffset = endOffset
        self.error = error
    }

    /// Lag counts offset positions, not necessarily messages (e.g. compacted topics).
    /// Unknown commits and offsets outside the retained log are not zero lag.
    public var lag: Int64? {
        guard error == nil, let committedOffset, let beginningOffset, let endOffset,
              beginningOffset >= 0, committedOffset >= beginningOffset,
              endOffset >= committedOffset else { return nil }
        return endOffset - committedOffset
    }

    public var isOutsideLog: Bool {
        guard let committedOffset, let beginningOffset, let endOffset else { return false }
        return committedOffset < beginningOffset || committedOffset > endOffset
    }
}

/// Optional capability so older plugins can still load without these methods.
public protocol WorkspaceKafkaConsumerGroupProviding: WorkspaceSession {
    func fetchConsumerGroups() async throws -> [WorkspaceKafkaConsumerGroup]
    func fetchConsumerOffsets(groupID: String, topic: String) async throws -> [WorkspaceKafkaConsumerOffset]
}

public struct WorkspaceKafkaConsumerMember: Equatable, Identifiable, Sendable {
    public let id: String
    public let clientID: String
    public let host: String
    public let instanceID: String?
    /// Assigned partitions in the topic requested by the caller.
    public let partitions: [Int32]

    public init(id: String, clientID: String, host: String, instanceID: String?, partitions: [Int32]) {
        self.id = id
        self.clientID = clientID
        self.host = host
        self.instanceID = instanceID
        self.partitions = partitions
    }
}

public struct WorkspaceKafkaConsumerGroupDetails: Equatable, Sendable {
    public let state: String
    public let assignor: String
    public let members: [WorkspaceKafkaConsumerMember]

    public init(state: String, assignor: String, members: [WorkspaceKafkaConsumerMember]) {
        self.state = state
        self.assignor = assignor
        self.members = members
    }
}

/// Optional so older driver bundles remain compatible with the host.
public protocol WorkspaceKafkaConsumerGroupDetailsProviding: WorkspaceSession {
    func fetchConsumerGroupDetails(groupID: String, topic: String) async throws -> WorkspaceKafkaConsumerGroupDetails
}

enum WorkspaceKafkaConsumerGroupError: LocalizedError {
    case driverUpdateRequired
    var errorDescription: String? {
        AppCopy.current.text("请更新 Kafka 插件以使用此功能。", "Update the Kafka plugin to use this feature.")
    }
}

extension WorkspaceKafkaConsumerOffset {
    /// Kafka commits the next offset to consume; do not increment it or reset the group.
    var pendingMessagesReadRequest: WorkspaceKafkaReadRequest? {
        guard partition >= 0, let lag, lag > 0, let committedOffset else { return nil }
        return WorkspaceKafkaReadRequest(partition: partition, start: .offset(committedOffset))
    }
}
