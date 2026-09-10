import Foundation

struct WorkspacePreparedIndexDeletion: Equatable, Sendable {
    let selection: WorkspaceDatabaseObjectSelection
    let request: WorkspaceRequest
    var verificationRequest: WorkspaceRequest { .init(method: .head, path: request.path) }
    var resolutionRequest: WorkspaceRequest {
        .init(method: .get, path: "/_resolve/index" + request.path + "?expand_wildcards=all")
    }
}

enum WorkspaceIndexDeletionError: LocalizedError {
    case ordinaryIndexRequired, pendingChanges

    var errorDescription: String? { message(copy: .current) }
    func message(copy: AppCopy) -> String {
        switch self {
        case .ordinaryIndexRequired:
            copy.text("这里只能删除一个普通索引，不能删除 Alias、Data Stream 或其 backing index。",
                      "Only a single ordinary index can be deleted here, not an Alias, Data Stream or its backing index.")
        case .pendingChanges:
            copy.text("工作区有未提交的更改。请先提交或放弃，再删除索引。",
                      "This workspace has pending changes. Commit or discard them before deleting an index.")
        }
    }
}

struct WorkspaceIndexDeletionNotSentError: LocalizedError {
    let message: String
    var response: WorkspaceRequestExecutionResult? = nil
    var errorDescription: String? { message }
}

actor WorkspaceIndexDeletionWorker {
    enum Outcome { case deleted, absent, rejected, uncertain }

    static func offersDeletion(_ selection: WorkspaceDatabaseObjectSelection) -> Bool {
        selection.kind == .elasticsearchIndex && !selection.objectName.hasPrefix(".ds-")
    }

    func prepare(_ selection: WorkspaceDatabaseObjectSelection) throws -> WorkspacePreparedIndexDeletion {
        try Task.checkCancellation()
        guard Self.offersDeletion(selection) else { throw WorkspaceIndexDeletionError.ordinaryIndexRequired }
        let path = try WorkspaceElasticsearchIndexName.encodedPath(selection.objectName)
        let request = WorkspaceRequest(method: .delete, path: path)
        try WorkspaceRequestClassifier.validate(request, policy: .writesAllowed)
        return .init(selection: selection, request: request)
    }

    /// This narrows a stale catalog selection immediately before DELETE. ES has
    /// no UUID/CAS parameter for index deletion; it is not an atomic identity lock.
    func validateResolution(_ response: WorkspaceRequestExecutionResult, for prepared: WorkspacePreparedIndexDeletion) throws -> Bool {
        try Task.checkCancellation()
        if isMissingIndex(response) { return false }
        guard response.statusCode == 200 else {
            throw WorkspaceIndexDeletionNotSentError(message: AppCopy.current.text(
                "无法核对索引（HTTP \(response.statusCode)），未发送删除请求。",
                "Unable to verify the index (HTTP \(response.statusCode)); deletion was not sent."
            ), response: response)
        }
        struct Resolution: Decodable {
            struct Index: Decodable { let name: String; let data_stream: String? }
            let indices: [Index]
        }
        guard let root = try? JSONDecoder().decode(Resolution.self, from: response.body),
              root.indices.count == 1, let index = root.indices.first,
              index.name == prepared.selection.objectName, index.data_stream == nil else {
            throw WorkspaceIndexDeletionNotSentError(
                message: WorkspaceIndexDeletionError.ordinaryIndexRequired.localizedDescription, response: response)
        }
        return true
    }

    func outcome(_ response: WorkspaceRequestExecutionResult) -> Outcome {
        if isMissingIndex(response) { return .absent }
        if response.statusCode == 408 || response.statusCode >= 500 { return .uncertain }
        guard (200..<300).contains(response.statusCode) else { return .rejected }
        struct Acknowledgement: Decodable { let acknowledged: Bool }
        guard let result = try? JSONDecoder().decode(Acknowledgement.self, from: response.body),
              result.acknowledged else { return .uncertain }
        return .deleted
    }

    func responseText(_ response: WorkspaceRequestExecutionResult) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    private func isMissingIndex(_ response: WorkspaceRequestExecutionResult) -> Bool {
        guard response.statusCode == 404 else { return false }
        struct Failure: Decodable {
            struct Reason: Decodable { let type: String }
            let error: Reason
        }
        return (try? JSONDecoder().decode(Failure.self, from: response.body))?.error.type == "index_not_found_exception"
    }
}
