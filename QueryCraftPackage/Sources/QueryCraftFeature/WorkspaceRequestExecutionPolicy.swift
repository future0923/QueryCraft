import Foundation

public enum WorkspaceRequestExecutionPolicy: Sendable, Equatable {
    case readOnly
    case writesAllowed
}

public enum WorkspaceRequestClassifier {
    public static func requiresWriteAccess(_ request: WorkspaceRequest) -> Bool {
        switch request.method {
        case .get, .head: false
        case .post: !WorkspaceReadOnlyRequestValidator.supportsReadOnlyPost(path: request.path)
        case .put, .delete: true
        }
    }

    public static func validate(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) throws {
        try WorkspaceReadOnlyRequestValidator.validateRelativePath(request.path)
        // GET bodies only have a transport equivalent for known read endpoints.
        if request.method == .get, request.body?.isEmpty == false {
            try WorkspaceReadOnlyRequestValidator.validate(request)
        }
        if policy == .readOnly { try WorkspaceReadOnlyRequestValidator.validate(request) }
    }

    public static func isNDJSON(path: String) -> Bool {
        let parts = URLComponents(string: path)?.path.split(separator: "/") ?? []
        return ["_bulk", "_msearch"].contains(parts.last.map(String.init) ?? "")
            || parts.suffix(2).map(String.init) == ["_msearch", "template"]
    }

    public static func requiresDangerousConfirmation(_ request: WorkspaceRequest) -> Bool {
        guard requiresWriteAccess(request) else { return false }
        let parts = URLComponents(string: request.path)?.path.split(separator: "/") ?? []
        // A single explicitly identified document is the only ordinary write.
        if parts.count == 3, ["_doc", "_create", "_update"].contains(String(parts[1])),
           !parts[0].contains("*"), !parts[0].contains(","), !parts[0].contains("?") {
            return false
        }
        return true
    }
}
