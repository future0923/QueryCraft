import Foundation

public enum KafkaSASLMechanism: String, CaseIterable, Codable, Identifiable, Sendable {
    case plain = "PLAIN"
    case scramSHA256 = "SCRAM-SHA-256"
    case scramSHA512 = "SCRAM-SHA-512"

    public var id: String { rawValue }
}

/// Optional session capability; keeps existing connection configuration and
/// driver protocol layouts unchanged for installed plugins.
public protocol WorkspaceKafkaAuthenticationConfiguring: WorkspaceSession {
    func configureSASL(_ mechanism: KafkaSASLMechanism) async throws
}

enum WorkspaceKafkaAuthentication {
    static func configure(_ session: any WorkspaceSession,
                          configuration: DatabaseConnectionConfiguration,
                          mechanism: KafkaSASLMechanism) async throws {
        guard configuration.databaseType == .kafka,
              configuration.authentication.method == .usernamePassword else { return }
        if let configurable = session as? any WorkspaceKafkaAuthenticationConfiguring {
            try await configurable.configureSASL(mechanism)
        } else if mechanism != .plain {
            throw KafkaAuthenticationError.driverUpdateRequired
        }
    }
}

enum KafkaAuthenticationError: LocalizedError {
    case driverUpdateRequired
    var errorDescription: String? {
        AppCopy.current.text("请更新 Kafka 插件以使用 SCRAM 认证。", "Update the Kafka plugin to use SCRAM authentication.")
    }
}
