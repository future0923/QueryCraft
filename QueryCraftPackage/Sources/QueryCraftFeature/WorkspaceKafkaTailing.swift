import Foundation

public struct WorkspaceKafkaTailBatch: Sendable {
    public let data: WorkspaceDatabaseDataBatch
    public let received: Int
    public let nextOffsets: [Int32: Int64]

    public init(data: WorkspaceDatabaseDataBatch, received: Int, nextOffsets: [Int32: Int64]) {
        self.data = data
        self.received = received
        self.nextOffsets = nextOffsets
    }
}

/// Optional, read-only streaming capability. Cursors are next offsets; never group commits.
public protocol WorkspaceKafkaTailing: WorkspaceSession {
    func tailStartingOffsets(topic: String, partition: Int32?) async throws -> [Int32: Int64]
    func pollTail(topic: String, offsets: [Int32: Int64], filter: WorkspaceKafkaScanRequest?) async throws -> WorkspaceKafkaTailBatch
}

struct WorkspaceKafkaLivePageInfo: Equatable, Sendable {
    let id: UUID
    let firstSequence: Int
    let scrollRequest: Int
}
