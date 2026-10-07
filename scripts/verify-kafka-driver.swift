import Foundation
import QueryCraftFeature

/// Checks the packaged plugin boundary, not a statically linked test target.
/// Does not connect to a broker or modify saved application profiles.
@main
struct VerifyKafkaDriver {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Usage: verify-kafka-driver /path/to/Kafka.querycraftdriver")
        }
        try bundle.loadAndReturnError()
        guard let entry = bundle.principalClass as? QueryCraftDriverBundleEntry.Type else {
            fatalError("Kafka plugin activation interface is unavailable")
        }
        try await entry.init().activate()
        let session = try await DatabaseDriverRegistry.shared.makeSession(configuration: .init(
            databaseType: .kafka, host: "127.0.0.1", port: 9092,
            authentication: .none, database: nil, tlsMode: .disabled
        ))
        guard session is any WorkspaceKafkaReading,
              session is any WorkspaceKafkaScanning,
              session is any WorkspaceKafkaTailing,
              session is any WorkspaceKafkaProducing,
              session is any WorkspaceKafkaConsumerGroupProviding,
              session is any WorkspaceKafkaTopicDetailsProviding,
              session is any WorkspaceKafkaTopicDeleting,
              session is any WorkspaceKafkaTopicConfigurationEditing,
              session is any WorkspaceKafkaGroupTopicMembershipProviding,
              session is any WorkspaceKafkaConsumerGroupDetailsProviding,
              let authentication = session as? any WorkspaceKafkaAuthenticationConfiguring else {
            fatalError("Packaged Kafka session is missing browsing, topic administration, consumer groups, or SASL support")
        }
        for mechanism in KafkaSASLMechanism.allCases {
            try await authentication.configureSASL(mechanism)
        }
        await session.close()
        print("Packaged Kafka plugin verified: reading, bounded scanning, live reading, producing, topic details, configuration editing, topic deletion, topic group membership, consumer groups and members, PLAIN, SCRAM-SHA-256, SCRAM-SHA-512")
    }
}
