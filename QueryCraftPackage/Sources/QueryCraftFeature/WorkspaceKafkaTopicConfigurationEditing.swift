import Foundation

public struct WorkspaceKafkaTopicConfigurationChange: Equatable, Identifiable, Sendable {
    public let original: WorkspaceKafkaTopicConfiguration
    /// nil removes the topic override and inherits the broker default.
    public let value: String?
    public var id: String { original.name }

    public init(original: WorkspaceKafkaTopicConfiguration, value: String?) {
        self.original = original
        self.value = value
    }
}

public struct WorkspaceKafkaTopicConfigurationRequest: Equatable, Sendable {
    public let topic: String
    public let changes: [WorkspaceKafkaTopicConfigurationChange]

    public init(topic: String, changes: [WorkspaceKafkaTopicConfigurationChange]) {
        self.topic = topic
        self.changes = changes
    }

    public func validate() throws {
        guard !topic.isEmpty, !topic.contains("\0"), !changes.isEmpty,
              Set(changes.map(\.id)).count == changes.count else {
            throw WorkspaceKafkaTopicConfigurationError.invalidRequest
        }
        for change in changes {
            guard !change.id.isEmpty, !change.id.contains("\0"),
                  !change.original.isSensitive, !change.original.isReadOnly else {
                throw WorkspaceKafkaTopicConfigurationError.invalidRequest
            }
            guard let value = change.value else { continue }
            guard !value.contains("\0"), value.utf8.count <= 1_048_576 else {
                throw WorkspaceKafkaTopicConfigurationError.invalidRequest
            }
            if change.id == "cleanup.policy" {
                guard ["delete", "compact", "compact,delete", "delete,compact"].contains(value) else {
                    throw WorkspaceKafkaTopicConfigurationError.invalidRequest
                }
            } else if ["retention.ms", "retention.bytes"].contains(change.id) {
                guard let number = Int64(value), number >= -1 else {
                    throw WorkspaceKafkaTopicConfigurationError.invalidRetention
                }
            }
        }
    }

    public func validateCurrent(_ configurations: [WorkspaceKafkaTopicConfiguration]) throws {
        try validate()
        for change in changes {
            guard configurations.first(where: { $0.name == change.id }) == change.original else {
                throw WorkspaceKafkaTopicConfigurationError.conflict
            }
        }
    }
}

/// Optional capability so older drivers continue to load without changing WorkspaceSession.
public protocol WorkspaceKafkaTopicConfigurationEditing: WorkspaceSession {
    func updateTopicConfiguration(_ request: WorkspaceKafkaTopicConfigurationRequest) async throws
}

public enum WorkspaceKafkaTopicConfigurationError: LocalizedError {
    case invalidRequest, invalidRetention, conflict, unavailable, driverUpdateRequired
    case rejected(String)

    public var errorDescription: String? {
        let copy = AppCopy.current
        switch self {
        case .invalidRequest: return copy.text("Topic 配置修改无效。", "Invalid topic configuration change.")
        case .invalidRetention: return copy.text("保留时间和大小须为 -1 或非负整数，且不能超过 Int64 范围。", "Retention must be -1 or a nonnegative Int64 integer.")
        case .conflict: return copy.text("配置已被其他操作修改，请重新读取后再编辑。", "Configuration changed since it was loaded. Reload before editing.")
        case .unavailable: return copy.text("未能读取完整配置，暂时无法编辑。", "The configuration could not be read completely. Editing is unavailable.")
        case .driverUpdateRequired: return copy.text("请更新 Kafka 插件以支持配置编辑。", "Update the Kafka plugin to edit topic configuration.")
        case .rejected(let message): return copy.text("配置被拒绝：", "Configuration rejected: ") + message
        }
    }
}
