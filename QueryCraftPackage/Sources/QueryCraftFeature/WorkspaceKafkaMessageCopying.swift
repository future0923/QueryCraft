import Foundation

public struct WorkspaceKafkaMessageReference: Equatable, Sendable {
    public let topic: String
    public let partition: Int32
    public let offset: Int64

    public init(topic: String, partition: Int32, offset: Int64) {
        self.topic = topic; self.partition = partition; self.offset = offset
    }
}

public struct WorkspaceKafkaMessagePayload: Equatable, Sendable {
    public let key: Data?
    public let value: Data?
    public let headers: [WorkspaceKafkaProducerHeader]

    public init(key: Data?, value: Data?, headers: [WorkspaceKafkaProducerHeader]) {
        self.key = key; self.value = value; self.headers = headers
    }
}

/// Reads the exact record, never the next available offset after retention/compaction.
public protocol WorkspaceKafkaMessageCopying: WorkspaceSession {
    func messageForCopy(_ reference: WorkspaceKafkaMessageReference) async throws -> WorkspaceKafkaMessagePayload
}

public enum WorkspaceKafkaMessageCopyError: LocalizedError {
    case unavailable, driverUpdateRequired, invalidBase64

    public var errorDescription: String? {
        switch self {
        case .unavailable: AppCopy.current.text("原消息已不可用，请刷新 Topic 后重试。", "The original message is unavailable. Refresh the topic and try again.")
        case .driverUpdateRequired: AppCopy.current.text("请更新 Kafka 插件以支持复制消息。", "Update the Kafka plugin to copy messages.")
        case .invalidBase64: AppCopy.current.text("Base64 内容无效。", "Invalid Base64 content.")
        }
    }
}
