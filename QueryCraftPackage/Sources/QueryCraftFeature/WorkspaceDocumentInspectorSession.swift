import Foundation

public struct WorkspaceDocumentReference: Hashable, Sendable {
    public let index: String
    public let id: String
    public let routing: String?

    public init(index: String, id: String, routing: String? = nil) {
        self.index = index
        self.id = id
        self.routing = routing
    }
}

public struct WorkspaceDocumentSnapshot: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference
    public let version: Int?
    public let sequenceNumber: Int64?
    public let primaryTerm: Int64?
    public let score: Double?
    public let sourceJSON: Data
    public let isTruncated: Bool

    public init(
        reference: WorkspaceDocumentReference,
        version: Int?,
        sequenceNumber: Int64? = nil,
        primaryTerm: Int64? = nil,
        score: Double?,
        sourceJSON: Data,
        isTruncated: Bool
    ) {
        self.reference = reference
        self.version = version
        self.sequenceNumber = sequenceNumber
        self.primaryTerm = primaryTerm
        self.score = score
        self.sourceJSON = sourceJSON
        self.isTruncated = isTruncated
    }
}

public protocol WorkspaceDocumentInspectorSession: WorkspaceSession {
    func fetchDocument(
        _ reference: WorkspaceDocumentReference,
        maximumByteCount: Int
    ) async throws -> WorkspaceDocumentSnapshot
}
