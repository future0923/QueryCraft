import Foundation

public enum WorkspaceDocumentCreationTargetKind: String, Sendable {
    case index
    case alias
    case dataStream
}

public struct WorkspaceDocumentCreationDraft: Equatable, Sendable {
    public let targetName: String
    public let targetKind: WorkspaceDocumentCreationTargetKind
    public let id: String?
    public let routing: String?
    public let sourceJSON: Data

    public init(
        targetName: String,
        targetKind: WorkspaceDocumentCreationTargetKind,
        id: String? = nil,
        routing: String? = nil,
        sourceJSON: Data
    ) {
        self.targetName = targetName
        self.targetKind = targetKind
        self.id = id
        self.routing = routing
        self.sourceJSON = sourceJSON
    }
}

public struct WorkspacePreparedDocumentCreation: Equatable, Sendable {
    public let draft: WorkspaceDocumentCreationDraft
    public let request: WorkspaceRequest

    public init(
        draft: WorkspaceDocumentCreationDraft,
        request: WorkspaceRequest
    ) {
        self.draft = draft
        self.request = request
    }
}

public struct WorkspaceDocumentCreationResult: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference
    public let version: Int?
    public let sequenceNumber: Int64
    public let primaryTerm: Int64

    public init(
        reference: WorkspaceDocumentReference,
        version: Int?,
        sequenceNumber: Int64,
        primaryTerm: Int64
    ) {
        self.reference = reference
        self.version = version
        self.sequenceNumber = sequenceNumber
        self.primaryTerm = primaryTerm
    }
}

public struct WorkspaceDocumentReplacementDraft: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference
    public let sequenceNumber: Int64
    public let primaryTerm: Int64
    public let sourceJSON: Data

    public init(
        reference: WorkspaceDocumentReference,
        sequenceNumber: Int64,
        primaryTerm: Int64,
        sourceJSON: Data
    ) {
        self.reference = reference
        self.sequenceNumber = sequenceNumber
        self.primaryTerm = primaryTerm
        self.sourceJSON = sourceJSON
    }
}

public struct WorkspacePreparedDocumentReplacement: Equatable, Sendable {
    public let draft: WorkspaceDocumentReplacementDraft
    public let request: WorkspaceRequest

    public init(
        draft: WorkspaceDocumentReplacementDraft,
        request: WorkspaceRequest
    ) {
        self.draft = draft
        self.request = request
    }
}

public struct WorkspaceDocumentPartialUpdateDraft: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference
    public let sequenceNumber: Int64
    public let primaryTerm: Int64
    public let sourceJSON: Data
    public let changedFieldsJSON: Data

    public init(
        reference: WorkspaceDocumentReference,
        sequenceNumber: Int64,
        primaryTerm: Int64,
        sourceJSON: Data,
        changedFieldsJSON: Data
    ) {
        self.reference = reference
        self.sequenceNumber = sequenceNumber
        self.primaryTerm = primaryTerm
        self.sourceJSON = sourceJSON
        self.changedFieldsJSON = changedFieldsJSON
    }
}

public struct WorkspacePreparedDocumentPartialUpdate: Equatable, Sendable {
    public let draft: WorkspaceDocumentPartialUpdateDraft
    public let request: WorkspaceRequest

    public init(
        draft: WorkspaceDocumentPartialUpdateDraft,
        request: WorkspaceRequest
    ) {
        self.draft = draft
        self.request = request
    }
}

public struct WorkspaceDocumentDeletionDraft: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference
    public let sequenceNumber: Int64
    public let primaryTerm: Int64

    public init(
        reference: WorkspaceDocumentReference,
        sequenceNumber: Int64,
        primaryTerm: Int64
    ) {
        self.reference = reference
        self.sequenceNumber = sequenceNumber
        self.primaryTerm = primaryTerm
    }
}

public struct WorkspacePreparedDocumentDeletion: Equatable, Sendable {
    public let draft: WorkspaceDocumentDeletionDraft
    public let request: WorkspaceRequest

    public init(
        draft: WorkspaceDocumentDeletionDraft,
        request: WorkspaceRequest
    ) {
        self.draft = draft
        self.request = request
    }
}

public struct WorkspaceDocumentDeletionResult: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference

    public init(reference: WorkspaceDocumentReference) {
        self.reference = reference
    }
}

public struct WorkspaceDocumentReplacementResult: Equatable, Sendable {
    public let reference: WorkspaceDocumentReference
    public let version: Int?
    public let sequenceNumber: Int64
    public let primaryTerm: Int64

    public init(
        reference: WorkspaceDocumentReference,
        version: Int?,
        sequenceNumber: Int64,
        primaryTerm: Int64
    ) {
        self.reference = reference
        self.version = version
        self.sequenceNumber = sequenceNumber
        self.primaryTerm = primaryTerm
    }
}

public enum WorkspaceDocumentEditingError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidSource
    case sourceTooLarge(Int)
    case missingConcurrencyMetadata
    case conflict
    case documentNotFound
    case documentAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            AppCopy.current.text(
                "当前连接不支持修改文档。",
                "This connection does not support document editing."
            )
        case .invalidSource:
            AppCopy.current.text(
                "_source 必须是有效的 JSON 对象。",
                "_source must be a valid JSON object."
            )
        case .sourceTooLarge(let maximumByteCount):
            AppCopy.current.text(
                "文档超过 \(maximumByteCount) 字节编辑上限。",
                "The document exceeds the \(maximumByteCount)-byte editing limit."
            )
        case .missingConcurrencyMetadata:
            AppCopy.current.text(
                "文档缺少并发版本信息，请重新加载后再试。",
                "The document is missing concurrency metadata. Reload it and try again."
            )
        case .conflict:
            AppCopy.current.text(
                "文档已在服务器上发生变化，请重新加载后再编辑。",
                "The document changed on the server. Reload it before editing again."
            )
        case .documentNotFound:
            AppCopy.current.text(
                "文档已不存在，请重新加载文档列表。",
                "The document no longer exists. Reload the document list."
            )
        case .documentAlreadyExists:
            AppCopy.current.text(
                "指定 _id 的文档已存在，请更换 _id 后再试。",
                "A document with the specified _id already exists. Choose another _id and try again."
            )
        }
    }
}

public protocol WorkspaceDocumentEditingSession: WorkspaceSession {
    func prepareDocumentCreation(
        _ draft: WorkspaceDocumentCreationDraft
    ) async throws -> WorkspacePreparedDocumentCreation

    func commitDocumentCreation(
        _ creation: WorkspacePreparedDocumentCreation
    ) async throws -> WorkspaceDocumentCreationResult

    func prepareDocumentReplacement(
        _ draft: WorkspaceDocumentReplacementDraft
    ) async throws -> WorkspacePreparedDocumentReplacement

    func commitDocumentReplacement(
        _ replacement: WorkspacePreparedDocumentReplacement
    ) async throws -> WorkspaceDocumentReplacementResult

    func prepareDocumentPartialUpdate(
        _ draft: WorkspaceDocumentPartialUpdateDraft
    ) async throws -> WorkspacePreparedDocumentPartialUpdate

    func commitDocumentPartialUpdate(
        _ update: WorkspacePreparedDocumentPartialUpdate
    ) async throws -> WorkspaceDocumentReplacementResult

    func prepareDocumentDeletion(
        _ draft: WorkspaceDocumentDeletionDraft
    ) async throws -> WorkspacePreparedDocumentDeletion

    func commitDocumentDeletion(
        _ deletion: WorkspacePreparedDocumentDeletion
    ) async throws -> WorkspaceDocumentDeletionResult
}
