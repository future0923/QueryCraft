import Foundation

enum MCPRequestAuthorization {
    static func index(_ path: String) -> String? {
        URLComponents(string: path)?.path.split(separator: "/").first.map(String.init)
    }

    static func validate(_ request: WorkspaceRequest, allowed: Set<String>?) throws {
        try WorkspaceReadOnlyRequestValidator.validateRelativePath(request.path)
        guard let allowed else { return }
        guard let components = URLComponents(string: request.path),
              !components.percentEncodedPath.contains("%") else { throw MCPFailure("Encoded scoped REST paths are not supported.") }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard let index = parts.first, allowed.contains(index), !index.hasPrefix("_"),
              !index.contains(where: { "*,?:<>".contains($0) }),
              !parts.contains(where: { $0.isEmpty }), (1...3).contains(parts.count) else {
            throw MCPFailure("REST request is outside the authorized index scope.")
        }
        let route = parts.count > 1 ? parts[1] : ""
        guard (parts.count == 1 && [.get, .head].contains(request.method))
                || (parts.count == 2 && ["_search", "_count", "_mapping"].contains(route))
                || (parts.count == 3 && ["_doc", "_create", "_update"].contains(route)) else {
            throw MCPFailure("REST route cannot be verified within an index scope.")
        }
        let safeQueryKeys: Set<String> = ["size", "from", "q", "sort", "_source", "_source_includes", "_source_excludes", "pretty", "human", "filter_path", "routing", "refresh", "timeout", "track_total_hits", "version", "if_seq_no", "if_primary_term"]
        guard components.queryItems?.allSatisfy({ safeQueryKeys.contains($0.name) }) != false else {
            throw MCPFailure("REST query parameters cannot be verified within an index scope.")
        }
        if let body = request.body {
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw MCPFailure("REST body must be a JSON object.") }
            // Search lookups, scripts and ingest pipelines can reference other indices.
            func verify(_ value: Any) throws {
                if let object = value as? [String: Any] {
                    let forbidden: Set<String> = ["index", "indices", "_index", "script", "script_fields", "runtime_mappings", "pipeline", "pit", "lookup", "percolate", "indexed_shape"]
                    guard forbidden.isDisjoint(with: object.keys) else { throw MCPFailure("REST body can reference data outside the authorized index.") }
                    for value in object.values { try verify(value) }
                } else if let array = value as? [Any] { for value in array { try verify(value) } }
            }
            try verify(json)
        }
    }
}
