import Foundation

public protocol WorkspaceKafkaTopicDeleting: WorkspaceSession {
    func deleteTopic(name: String) async throws
}

public struct WorkspaceKafkaTopicDeletionRequest: Equatable, Sendable {
    public let topic: String

    public init(topic: String) { self.topic = topic }

    public func validate() throws {
        guard !topic.isEmpty, topic.utf8.count <= 249, topic != ".", topic != "..",
              topic.unicodeScalars.allSatisfy({ scalar in
                  [45, 46, 95].contains(scalar.value) || (48...57).contains(scalar.value)
                      || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
              }) else { throw WorkspaceKafkaTopicDeletionError.invalidName }
        guard !topic.hasPrefix("__") else { throw WorkspaceKafkaTopicDeletionError.internalTopic }
    }
}

public enum WorkspaceKafkaTopicDeletionError: LocalizedError, Sendable {
    case invalidName, internalTopic, driverUpdateRequired, pendingChanges
    case notSent(String), rejected(String), unconfirmed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            AppCopy.current.text("请选择一个有效的 Topic，不支持通配符或批量删除。", "Select one valid topic. Wildcards and bulk deletion are not supported.")
        case .internalTopic:
            AppCopy.current.text("不能在这里删除 Kafka 内部 Topic。", "Kafka internal topics cannot be deleted here.")
        case .driverUpdateRequired:
            AppCopy.current.text("请更新 Kafka 插件以支持删除 Topic。", "Update the Kafka plugin to delete topics.")
        case .pendingChanges:
            AppCopy.current.text("此 Topic 有未提交的配置更改，请先提交或放弃。", "This topic has pending configuration changes. Commit or discard them first.")
        case .notSent(let message): message
        case .rejected(let message):
            AppCopy.current.text("删除被拒绝：", "Deletion rejected: ") + message
        case .unconfirmed(let message):
            AppCopy.current.text("删除结果未确认。请关闭弹窗并刷新 Topic 列表核实后再操作：", "Deletion is unconfirmed. Close this dialog and refresh the topic list to verify before trying again: ") + message
        }
    }
}
