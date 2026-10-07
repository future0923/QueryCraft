import Foundation

public struct WorkspaceKafkaProducerHeader: Equatable, Sendable {
    public let name: String
    public let value: Data?
    public init(name: String, value: Data?) { self.name = name; self.value = value }
}

public struct WorkspaceKafkaProduceRequest: Equatable, Sendable {
    public let topic: String
    public let partition: Int32?
    public let key: Data?
    public let value: Data
    public let isNullValue: Bool
    public let headers: [WorkspaceKafkaProducerHeader]
    public static let maximumBytes = 1_048_576

    public init(topic: String, partition: Int32? = nil, key: Data? = nil,
                value: Data, headers: [WorkspaceKafkaProducerHeader] = []) {
        self.init(topic: topic, partition: partition, key: key, value: value, headers: headers, isNullValue: false)
    }

    public init(topic: String, partition: Int32? = nil, key: Data? = nil,
                value: Data, headers: [WorkspaceKafkaProducerHeader] = [], isNullValue: Bool) {
        self.topic = topic; self.partition = partition; self.key = key
        self.value = isNullValue ? Data() : value; self.headers = headers
        self.isNullValue = isNullValue
    }

    public func validate() throws {
        guard !topic.isEmpty, topic.utf8.count <= 249, topic != ".", topic != "..",
              topic.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw WorkspaceKafkaProduceError.invalidTopic
        }
        guard partition == nil || partition! >= 0 else { throw WorkspaceKafkaProduceError.invalidPartition }
        guard headers.count <= 100, headers.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("\0") }) else {
            throw WorkspaceKafkaProduceError.invalidHeaders
        }
        let bytes = value.count + (key?.count ?? 0) + headers.reduce(0) { $0 + $1.name.utf8.count + ($1.value?.count ?? 0) }
        guard bytes <= Self.maximumBytes else { throw WorkspaceKafkaProduceError.tooLarge }
    }
}

public struct WorkspaceKafkaProduceReceipt: Equatable, Sendable {
    public let partition: Int32
    public let offset: Int64?
    public init(partition: Int32, offset: Int64?) { self.partition = partition; self.offset = offset }
}

/// Optional capability: returning a receipt requires a successful broker delivery report.
public protocol WorkspaceKafkaProducing: WorkspaceSession {
    func produce(_ request: WorkspaceKafkaProduceRequest) async throws -> WorkspaceKafkaProduceReceipt
}

public enum WorkspaceKafkaProduceError: LocalizedError {
    case invalidTopic, invalidPartition, invalidHeaders, tooLarge, driverUpdateRequired
    case deliveryUnconfirmed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidTopic: AppCopy.current.text("Topic 名称无效。", "Invalid topic name.")
        case .invalidPartition: AppCopy.current.text("分区必须是非负整数。", "Partition must be a nonnegative integer.")
        case .invalidHeaders: AppCopy.current.text("Header 名称不能为空或包含空字符，最多 100 项。", "Header names cannot be empty or contain NUL; at most 100 headers are allowed.")
        case .tooLarge: AppCopy.current.text("消息总大小不能超过 1 MB。", "The total message size must not exceed 1 MB.")
        case .driverUpdateRequired: AppCopy.current.text("请更新 Kafka 插件以支持发送消息。", "Update the Kafka plugin to send messages.")
        case .deliveryUnconfirmed(let reason):
            AppCopy.current.text("未确认发送成功：\(reason)。请先检查 Topic，避免重复发送。",
                                 "Delivery was not confirmed: \(reason). Check the topic before sending again to avoid duplicates.")
        }
    }
}
