import Foundation

public struct WorkspaceKafkaTopicPartition: Equatable, Identifiable, Sendable {
    public let id: Int32
    public let leader: Int32?
    public let replicas: [Int32]
    public let inSyncReplicas: [Int32]
    public let error: String?

    public init(id: Int32, leader: Int32?, replicas: [Int32], inSyncReplicas: [Int32], error: String? = nil) {
        self.id = id
        self.leader = leader
        self.replicas = replicas
        self.inSyncReplicas = inSyncReplicas
        self.error = error
    }

    public var isUnderReplicated: Bool { !Set(replicas).isSubset(of: Set(inSyncReplicas)) }
}

public struct WorkspaceKafkaTopicConfiguration: Equatable, Identifiable, Sendable {
    public let name: String
    public let value: String?
    public let isDefault: Bool
    public let isSensitive: Bool
    public let isReadOnly: Bool
    public var id: String { name }

    public init(name: String, value: String?, isDefault: Bool, isSensitive: Bool = false) {
        self.init(name: name, value: value, isDefault: isDefault, isSensitive: isSensitive, isReadOnly: false)
    }

    public init(name: String, value: String?, isDefault: Bool, isSensitive: Bool = false, isReadOnly: Bool) {
        self.name = name
        self.value = isSensitive ? nil : value
        self.isDefault = isDefault
        self.isSensitive = isSensitive
        self.isReadOnly = isReadOnly
    }
}

public struct WorkspaceKafkaTopicDetails: Equatable, Sendable {
    public let partitions: [WorkspaceKafkaTopicPartition]
    public let configurations: [WorkspaceKafkaTopicConfiguration]
    public let configurationError: String?

    public init(partitions: [WorkspaceKafkaTopicPartition], configurations: [WorkspaceKafkaTopicConfiguration],
                configurationError: String? = nil) {
        self.partitions = partitions
        self.configurations = configurations
        self.configurationError = configurationError
    }
}

public protocol WorkspaceKafkaTopicDetailsProviding: WorkspaceSession {
    func fetchTopicDetails(topic: String) async throws -> WorkspaceKafkaTopicDetails
}

public enum WorkspaceKafkaGroupTopicMembership: Int, Equatable, Sendable {
    case related, unknown, unrelated
}

public protocol WorkspaceKafkaGroupTopicMembershipProviding: WorkspaceSession {
    func fetchGroupTopicMembership(groupID: String, topic: String) async throws -> WorkspaceKafkaGroupTopicMembership
}

struct WorkspaceKafkaLagSummary: Equatable {
    let totalLag: Int64?
    let knownLag: Int64?
    let laggingPartitions: Int
    let unknownPartitions: Int

    init(offsets: [WorkspaceKafkaConsumerOffset]) {
        var sum: Int64? = 0
        for lag in offsets.compactMap(\.lag) {
            if let current = sum {
                let result = current.addingReportingOverflow(lag)
                sum = result.overflow ? nil : result.partialValue
            }
        }
        unknownPartitions = offsets.filter { $0.lag == nil }.count
        laggingPartitions = offsets.filter { ($0.lag ?? 0) > 0 }.count
        knownLag = offsets.isEmpty ? nil : sum
        totalLag = offsets.isEmpty || unknownPartitions > 0 ? nil : sum
    }
}
