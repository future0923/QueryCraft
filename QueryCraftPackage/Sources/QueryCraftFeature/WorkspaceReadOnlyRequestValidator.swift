import Foundation

public enum WorkspaceReadOnlyRequestValidator {
    public static func validate(_ request: WorkspaceRequest) throws {
        try validateRelativePath(request.path)
        switch request.method {
        case .get where request.body?.isEmpty == false:
            guard supportsEquivalentPost(path: request.path) else {
                throw WorkspaceReadOnlyRequestValidationError.unsupported(method: .get, path: request.path)
            }
        case .get, .head: return
        case .post where supportsReadOnlyPost(path: request.path): return
        default:
            throw WorkspaceReadOnlyRequestValidationError.unsupported(method: request.method, path: request.path)
        }
    }

    public static func validateRelativePath(_ path: String) throws {
        guard path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("\\"),
              let components = URLComponents(string: path),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              !components.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  let decoded = String($0).removingPercentEncoding ?? String($0)
                  return decoded == "." || decoded == ".." || decoded.contains("\\")
              })
        else {
            throw WorkspaceReadOnlyRequestValidationError.absoluteURL
        }
    }

    static func supportsReadOnlyPost(path: String) -> Bool {
        if supportsEquivalentPost(path: path) { return true }
        guard let components = URLComponents(string: path), components.fragment == nil else { return false }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty,
              parts[1] == "_index_template", parts[2] == "_simulate_index",
              let name = String(parts[3]).removingPercentEncoding,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else { return false }
        return true
    }

    // Match complete REST routes, not suffixes: a GET body must never turn an
    // unrelated endpoint into a POST. Query strings and encoded index/ID bytes
    // are preserved by transport; only the method changes.
    static func supportsEquivalentPost(path: String) -> Bool {
        guard let components = URLComponents(string: path), components.fragment == nil else { return false }
        let parts = components.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let basic: Set<Substring> = ["_search", "_count", "_msearch", "_field_caps", "_analyze"]
        if parts.count == 1 { return basic.contains(parts[0]) || parts[0] == "_sql" }
        if parts.count == 2 {
            if (!parts[0].hasPrefix("_") || parts[0] == "_all"), basic.contains(parts[1]) { return true }
            return parts == ["_validate", "query"] || parts == ["_search", "template"]
                || parts == ["_render", "template"] || parts == ["_msearch", "template"]
        }
        if parts.count == 3, !parts[0].hasPrefix("_") || parts[0] == "_all" {
            return parts[1] == "_explain"
                || parts.suffix(2) == ["_validate", "query"]
                || parts.suffix(2) == ["_search", "template"]
                || parts.suffix(2) == ["_eql", "search"]
                || parts.suffix(2) == ["_msearch", "template"]
        }
        return false
    }

}

public enum WorkspaceReadOnlyRequestValidationError: LocalizedError {
    case absoluteURL
    case unsupported(method: WorkspaceRequestMethod, path: String)

    public var errorDescription: String? {
        description(copy: .current)
    }

    func description(copy: AppCopy) -> String {
        switch self {
        case .absoluteURL:
            copy.text(
                "请求只能使用以 / 开头的相对路径。",
                "Requests must use a relative path beginning with /."
            )
        case .unsupported(let method, let path):
            method == .get ? copy.text(
                "此端点不支持 GET 请求体兼容：\(path)。请使用该端点文档规定的请求方法。",
                "GET request bodies cannot be adapted for this endpoint: \(path). Use the method documented for the endpoint."
            ) : copy.text(
                "只读控制台不允许 \(method.rawValue) \(path)。",
                "The read-only console does not allow \(method.rawValue) \(path)."
            )
        }
    }
}
