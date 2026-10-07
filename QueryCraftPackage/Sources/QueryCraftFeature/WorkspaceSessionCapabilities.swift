public struct WorkspaceSessionCapabilities: Equatable, Sendable {
    public enum ReadOnlyExecution: Equatable, Sendable {
        case serverEnforced
        case classifiedStatementsOnly
        case classifiedRequestsOnly
    }

    public let readOnlyExecution: ReadOnlyExecution
    public let supportsDataEditing: Bool
    public let supportsTransactions: Bool

    public init(
        readOnlyExecution: ReadOnlyExecution,
        supportsDataEditing: Bool,
        supportsTransactions: Bool
    ) {
        self.readOnlyExecution = readOnlyExecution
        self.supportsDataEditing = supportsDataEditing
        self.supportsTransactions = supportsTransactions
    }

    public static let standard = Self(
        readOnlyExecution: .serverEnforced,
        supportsDataEditing: true,
        supportsTransactions: true
    )

    public static let dorisReadOnly = Self(
        readOnlyExecution: .classifiedStatementsOnly,
        supportsDataEditing: false,
        supportsTransactions: false
    )

    public static let redis = Self(
        readOnlyExecution: .classifiedStatementsOnly,
        supportsDataEditing: true,
        supportsTransactions: true
    )

    public static let elasticsearch = Self(
        readOnlyExecution: .classifiedRequestsOnly,
        supportsDataEditing: true,
        supportsTransactions: false
    )

    public static let elasticsearchReadOnly = elasticsearch

    public static let kafka = Self(
        readOnlyExecution: .classifiedStatementsOnly,
        supportsDataEditing: false,
        supportsTransactions: false
    )
}

public protocol WorkspaceSessionCapabilityProviding: Sendable {
    var capabilities: WorkspaceSessionCapabilities { get }
}

/// Optional capability for sessions that can create a named Kafka topic.
/// Keeping this separate from the general session protocol avoids exposing
/// Kafka-specific mutation parameters to every database driver.
public protocol WorkspaceTopicCreationProviding: Sendable {
    func createTopic(
        name: String,
        partitions: Int32,
        replicationFactor: Int16
    ) async throws
}

public extension WorkspaceSession {
    var resolvedCapabilities: WorkspaceSessionCapabilities {
        (self as? any WorkspaceSessionCapabilityProviding)?.capabilities
            ?? .standard
    }
}
