import Foundation
import QueryCraftFeature

enum KafkaError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case network(String)
    case invalidResponse
    case protocolError(code: Int16, message: String?)
    case unsupportedCompression
    case unsupportedAuthentication
    case noLeader(topic: String, partition: Int32)
    case fetchNoProgress(topic: String, partition: Int32, offset: Int64, highWatermark: Int64)
    case messageDecode(String)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return AppCopy.current.text(
                "Kafka 连接配置无效：\(message)",
                "Invalid Kafka connection configuration: \(message)"
            )
        case let .network(message):
            return AppCopy.current.text(
                "Kafka 网络连接失败：\(message)",
                "Kafka network connection failed: \(message)"
            )
        case .invalidResponse:
            return AppCopy.current.text(
                "Kafka 返回了无法识别的响应。",
                "Kafka returned an invalid response."
            )
        case let .protocolError(code, message):
            let detail = message.map { ": \($0)" } ?? ""
            return AppCopy.current.text(
                "Kafka 协议错误 \(code)\(detail)",
                "Kafka protocol error \(code)\(detail)"
            )
        case .unsupportedCompression:
            return AppCopy.current.text(
                "当前 Kafka 驱动无法读取压缩消息批次。",
                "This Kafka driver cannot read compressed message batches."
            )
        case .unsupportedAuthentication:
            return AppCopy.current.text(
                "当前 Kafka 驱动只支持 SASL/PLAIN 认证。",
                "This Kafka driver supports SASL/PLAIN authentication only."
            )
        case let .noLeader(topic, partition):
            return AppCopy.current.text(
                "Topic \(topic) 的分区 \(partition) 没有可用 Leader。",
                "Topic \(topic) partition \(partition) has no available leader."
            )
        case let .fetchNoProgress(topic, partition, offset, highWatermark):
            return AppCopy.current.text(
                "Topic \(topic) 的分区 \(partition) 在偏移量 \(offset) 处没有返回消息，但高水位为 \(highWatermark)。",
                "Kafka returned no records for topic \(topic) partition \(partition) at offset \(offset) before high watermark \(highWatermark)."
            )
        case let .messageDecode(message):
            return AppCopy.current.text(
                "Kafka 消息无法解码：\(message)",
                "Kafka message could not be decoded: \(message)"
            )
        }
    }
}
