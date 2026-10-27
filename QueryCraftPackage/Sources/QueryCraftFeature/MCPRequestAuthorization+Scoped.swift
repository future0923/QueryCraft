import Foundation

extension MCPRequestAuthorization {
    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPFailure("REST body/header must be a JSON object.") }
            return object
        } catch let failure as MCPFailure { throw failure }
        catch { throw MCPFailure("REST body/header contains invalid JSON.") }
    }

    private static func validateSearchBody(_ json: [String: Any], allowed: Set<String>?) throws {
        if json["pit"] != nil { throw MCPFailure("Point-in-time search scope cannot be verified.", code: .unsupported) }
        func visit(_ value: Any) throws {
            if let object = value as? [String: Any] {
                if let index = object["index"] as? String, object["id"] != nil, allowed?.contains(index) == false {
                    throw MCPFailure("Query lookup references an unauthorized index.", code: .accessDenied)
                }
                for (key, child) in object {
                    if ["percolate", "indices"].contains(key), child is [String: Any] {
                        throw MCPFailure("Query scope cannot be verified for \(key).", code: .unsupported)
                    }
                    try visit(child)
                }
            } else if let array = value as? [Any] { for child in array { try visit(child) } }
        }
        if let query = json["query"] { try visit(query) }
        if let aggs = json["aggs"] ?? json["aggregations"] { try visit(aggs) }
    }
    static func names(_ path: String) -> [String] {
        guard let first = URLComponents(string: path)?.path.split(separator: "/").first,
              !first.hasPrefix("_"), !first.contains(where: { "*?:<>".contains($0) }) else { return [] }
        return first.split(separator: ",").map(String.init)
    }

    static func bulkTargets(_ request: WorkspaceRequest) throws -> [String] {
        let route = URLComponents(string: request.path)?.path.split(separator: "/").last.map(String.init)
        guard route == "_bulk" || route == "_msearch", let body = request.body else { return [] }
        let lines = String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline)
        var targets: [String] = [], cursor = 0
        while cursor < lines.count {
            let header = try jsonObject(Data(lines[cursor].utf8))
            let selected: [String]
            if route == "_bulk" {
                guard header.count == 1, let action = header.keys.first, ["index", "create", "update", "delete"].contains(action),
                      let metadata = header[action] as? [String: Any] else { throw MCPFailure("Invalid bulk action header.") }
                if metadata["pipeline"] != nil { throw MCPFailure("Ingest pipelines cannot be verified within object permissions.", code: .accessDenied) }
                selected = (metadata["_index"] as? String).map { [$0] } ?? names(request.path)
                let next = cursor + (action == "delete" ? 1 : 2)
                guard next <= lines.count else { throw MCPFailure("Bulk action body is missing.") }
                cursor = next
            } else {
                selected = (header["index"] as? String).map { $0.split(separator: ",").map(String.init) }
                    ?? header["index"] as? [String] ?? names(request.path)
                guard cursor + 1 < lines.count else { throw MCPFailure("Search body is missing.") }
                cursor += 2
            }
            if selected.isEmpty {
                guard route == "_msearch" else { throw MCPFailure("Bulk actions must name an index or use an explicit index path.") }
                targets.append("_all") // Valid global search; rejected below when an object scope applies.
            } else { targets += selected }
        }
        return targets
    }

    static func validateScoped(_ request: WorkspaceRequest, allowed: Set<String>?, objectOverrides: Bool = false) throws {
        do { try WorkspaceReadOnlyRequestValidator.validateRelativePath(request.path) }
        catch { throw MCPFailure("REST requests require a relative path without traversal.") }
        guard allowed != nil || objectOverrides else { return }
        guard let components = URLComponents(string: request.path), !components.percentEncodedPath.contains("%") else {
            throw MCPFailure("Encoded REST paths cannot be verified within object permissions.", code: .accessDenied)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        var targets = names(request.path)
        let route = parts.count > 1 ? parts[1] : (parts.first ?? "")
        if route == "_bulk" || route == "_msearch" { targets += try bulkTargets(request) }
        guard !targets.isEmpty, targets.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("_") && !$0.contains(where: { "*,?:<>/".contains($0) }) && (allowed?.contains($0) ?? true) }) else {
            throw MCPFailure("REST request is outside the authorized index scope or cannot resolve object overrides. Use explicit authorized index names.", code: .accessDenied)
        }
        let indexRoute = parts.count == 1 && !parts[0].hasPrefix("_")
        let rootBatch = parts.count == 1 && ["_bulk", "_msearch"].contains(route)
        let routes: Set<String> = ["_search", "_count", "_mapping", "_settings", "_refresh", "_flush", "_forcemerge", "_open", "_close", "_delete_by_query", "_update_by_query", "_bulk", "_msearch", "_field_caps", "_analyze"]
        guard indexRoute || rootBatch || (parts.count == 2 && routes.contains(route))
                || (parts.count == 3 && ["_doc", "_create", "_update"].contains(route)) else {
            throw MCPFailure("REST route cannot be verified within object permissions.", code: .unsupported)
        }
        if components.queryItems?.contains(where: { $0.name == "pipeline" && $0.value != "_none" }) == true {
            throw MCPFailure("Ingest pipelines can redirect documents outside the authorized indices.", code: .accessDenied)
        }
        if route == "_msearch", let body = request.body {
            let lines = String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline)
            for offset in stride(from: 1, to: lines.count, by: 2) {
                try validateSearchBody(jsonObject(Data(lines[offset].utf8)), allowed: allowed)
            }
        }
        guard let body = request.body, route != "_bulk", route != "_msearch" else { return }
        let json = try jsonObject(body)
        // Document contents (including fields named index/script/pipeline) are data.
        if ["_doc", "_create", "_update"].contains(route) { return }
        try validateSearchBody(json, allowed: allowed)
        if let aliases = json["aliases"] as? [String: Any], aliases.keys.contains(where: { allowed?.contains($0) == false }) {
            throw MCPFailure("Index creation includes an unauthorized alias.", code: .accessDenied)
        }
        if let settings = json["settings"] as? [String: Any] {
            let keys = ["default_pipeline", "final_pipeline", "index.default_pipeline", "index.final_pipeline"]
            let nested = settings["index"] as? [String: Any] ?? [:]
            if keys.contains(where: {
                guard let value = settings[$0] ?? nested[$0] else { return false }
                return !(value is NSNull) && value as? String != "_none"
            }) {
                throw MCPFailure("Pipeline settings can redirect future writes outside the authorized scope.", code: .accessDenied)
            }
        }
    }
}
