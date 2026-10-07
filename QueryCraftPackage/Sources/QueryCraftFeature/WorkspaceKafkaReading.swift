import Foundation

public struct WorkspaceKafkaReadRequest: Equatable, Sendable {
    public enum Start: Equatable, Sendable {
        case earliest
        /// Reads the last N offset positions in each selected partition.
        case latest(Int)
        case offset(Int64)
        case timestamp(Int64)
    }

    public let partition: Int32?
    public let start: Start

    public init(partition: Int32? = nil, start: Start = .earliest) {
        self.partition = partition
        self.start = start
    }

    public var isValid: Bool {
        if let partition, partition < 0 { return false }
        switch start {
        case .earliest: return true
        case .latest(let count): return count > 0
        case .offset(let value): return partition != nil && value >= 0
        case .timestamp(let value): return value >= 0
        }
    }
}

/// Optional Kafka capability; does not change the driver ABI's WorkspaceSession requirements.
public protocol WorkspaceKafkaReading: WorkspaceSession {
    func prepareReading(topic: String, request: WorkspaceKafkaReadRequest) async throws
}
