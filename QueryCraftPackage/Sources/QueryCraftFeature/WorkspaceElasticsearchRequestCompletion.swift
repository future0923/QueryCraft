#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

enum WorkspaceElasticsearchRequestCompletion {
    enum Kind {
        case method
        case resource(WorkspaceDatabaseObjectKind)
        case endpoint
        case key
        case queryClause
        case field
        case value
    }
    struct Endpoint {
        let path: String
        let allowsGET: Bool
        let allowsPOST: Bool
        let supportsResource: Bool
        var allowsPUT = false
        var allowsDELETE = false
    }

    enum RequestLineContext {
        case method(prefix: String)
        case path(method: WorkspaceRequestMethod)
    }

    static let requestMethods: [WorkspaceRequestMethod] = [
        .get, .post, .put, .delete, .head,
    ]
    static let endpoints = [
        Endpoint(path: "_doc/", allowsGET: true, allowsPOST: true, supportsResource: true, allowsPUT: true, allowsDELETE: true),
        Endpoint(path: "_create/", allowsGET: false, allowsPOST: true, supportsResource: true, allowsPUT: true),
        Endpoint(path: "_update/", allowsGET: false, allowsPOST: true, supportsResource: true),
        Endpoint(path: "_mapping", allowsGET: true, allowsPOST: true, supportsResource: true, allowsPUT: true),
        Endpoint(path: "_settings", allowsGET: true, allowsPOST: false, supportsResource: true, allowsPUT: true),
        Endpoint(path: "_aliases", allowsGET: false, allowsPOST: true, supportsResource: false),
        Endpoint(path: "_bulk", allowsGET: false, allowsPOST: true, supportsResource: true, allowsPUT: true),
        Endpoint(path: "_update_by_query", allowsGET: false, allowsPOST: true, supportsResource: true),
        Endpoint(path: "_delete_by_query", allowsGET: false, allowsPOST: true, supportsResource: true),
        Endpoint(path: "_reindex", allowsGET: false, allowsPOST: true, supportsResource: false),
        Endpoint(
            path: "_cluster/health",
            allowsGET: true,
            allowsPOST: false,
            supportsResource: false
        ),
        Endpoint(
            path: "_cat/indices?format=json",
            allowsGET: true,
            allowsPOST: false,
            supportsResource: false
        ),
        Endpoint(path: "_search", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_count", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_msearch", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_field_caps?fields=*", allowsGET: true,
                 allowsPOST: true, supportsResource: true),
        Endpoint(path: "_validate/query", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_analyze", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_explain", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_search/template", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
        Endpoint(path: "_render/template", allowsGET: true, allowsPOST: true,
                 supportsResource: false),
        Endpoint(path: "_sql", allowsGET: true, allowsPOST: true,
                 supportsResource: false),
        Endpoint(path: "_eql/search", allowsGET: true, allowsPOST: true,
                 supportsResource: true),
    ]
    struct PathSuggestion {
        let label: String
        let insertionText: String
        let kind: Kind
        let selectedRangeInInsertion: NSRange?
        let detail: String?

        init(
            label: String,
            insertionText: String,
            kind: Kind,
            selectedRangeInInsertion: NSRange? = nil,
            detail: String? = nil
        ) {
            self.label = label
            self.insertionText = insertionText
            self.kind = kind
            self.selectedRangeInInsertion = selectedRangeInInsertion
            self.detail = detail
        }
    }

    static func pathSuggestions(
        forPathPrefix prefix: String,
        method: WorkspaceRequestMethod,
        resources: [WorkspaceElasticsearchCompletionResource]
    ) -> [PathSuggestion] {
        if method == .head {
            return resourceSuggestions(
                forPathPrefix: prefix,
                method: method,
                resources: resources
            )
        }

        let lowercasePrefix = prefix.lowercased()
        if lowercasePrefix.isEmpty || lowercasePrefix == "/" {
            let resourceEntries = resourceSuggestions(
                forPathPrefix: prefix,
                method: method,
                resources: resources
            )
            let endpointEntries = allowedEndpoints(for: method)
                .map { endpoint in
                    let value = "/\(endpoint.path)"
                    return endpointSuggestion(
                        label: value,
                        path: value,
                        endpoint: endpoint,
                        hasResource: false
                    )
                }
            return resourceEntries + endpointEntries
        }
        if lowercasePrefix.hasPrefix("/_") {
            return allowedEndpoints(for: method).compactMap { endpoint in
                let value = "/\(endpoint.path)"
                guard value.lowercased().hasPrefix(lowercasePrefix) else {
                    return nil
                }
                return endpointSuggestion(
                    label: value,
                    path: value,
                    endpoint: endpoint,
                    hasResource: false
                )
            }
        }

        if let endpointBoundary = prefix.range(
            of: "/_",
            options: .backwards
        ), endpointBoundary.lowerBound > prefix.startIndex {
            let resourcePrefix = String(prefix[..<endpointBoundary.lowerBound])
            let endpointPrefix = String(prefix[endpointBoundary.upperBound...])
                .lowercased()
            return allowedEndpoints(for: method).compactMap { endpoint in
                guard endpoint.supportsResource,
                      endpoint.path.dropFirst().lowercased()
                        .hasPrefix(endpointPrefix)
                else { return nil }
                let value = "\(resourcePrefix)/\(endpoint.path)"
                return endpointSuggestion(
                    label: value,
                    path: value,
                    endpoint: endpoint,
                    hasResource: true
                )
            }
        }

        if prefix.hasSuffix("/") {
            let resourcePrefix = String(prefix.dropLast())
            return allowedEndpoints(for: method).compactMap { endpoint in
                guard endpoint.supportsResource else { return nil }
                let value = "\(resourcePrefix)/\(endpoint.path)"
                return endpointSuggestion(
                    label: value,
                    path: value,
                    endpoint: endpoint,
                    hasResource: true
                )
            }
        }

        return resourceSuggestions(
            forPathPrefix: prefix,
            method: method,
            resources: resources
        )
    }

    static func pathSuggestionTexts(
        forPathPrefix prefix: String,
        method: WorkspaceRequestMethod,
        resources: [WorkspaceElasticsearchCompletionResource]
    ) -> [String] {
        pathSuggestions(
            forPathPrefix: prefix,
            method: method,
            resources: resources
        ).map(\.insertionText)
    }

    static func resourceSuggestions(
        forPathPrefix prefix: String,
        method: WorkspaceRequestMethod,
        resources: [WorkspaceElasticsearchCompletionResource]
    ) -> [PathSuggestion] {
        let lowercasePrefix = prefix.lowercased()
        return resources.compactMap { resource in
            let label = "/\(resource.name)"
            guard lowercasePrefix.isEmpty
                    || label.lowercased().hasPrefix(lowercasePrefix)
            else { return nil }
            let insertionText = method == .head ? label : "\(label)/"
            return PathSuggestion(
                label: label,
                insertionText: insertionText,
                kind: .resource(resource.kind)
            )
        }
    }

    static func endpointSuggestion(
        label: String,
        path: String,
        endpoint: Endpoint,
        hasResource: Bool
    ) -> PathSuggestion {
        guard endpoint.path == "_msearch" else {
            return PathSuggestion(
                label: label,
                insertionText: path,
                kind: .endpoint
            )
        }

        let header = hasResource ? "{}" : "{\"index\": \"\"}"
        let insertion = "\(path)\n\(header)\n"
            + "{\"query\": {\"match_all\": {}}}\n"
        let selectionLocation = hasResource
            ? ("\(path)\n{}\n{\"query\": {\"" as NSString).length
            : ("\(path)\n{\"index\": \"" as NSString).length
        let selectionLength = hasResource ? ("match_all" as NSString).length : 0
        return PathSuggestion(
            label: label,
            insertionText: insertion,
            kind: .endpoint,
            selectedRangeInInsertion: NSRange(
                location: selectionLocation,
                length: selectionLength
            ),
            detail: AppCopy.current.text(
                "批量查询 · NDJSON",
                "Multi search · NDJSON"
            )
        )
    }

    static func allowedEndpoints(
        for method: WorkspaceRequestMethod
    ) -> [Endpoint] {
        endpoints.filter { endpoint in
            switch method {
            case .get: endpoint.allowsGET
            case .post: endpoint.allowsPOST
            case .head: endpoint.allowsGET
            case .put: endpoint.allowsPUT
            case .delete: endpoint.allowsDELETE
            }
        }
    }

    static func requestLineContext(
        _ line: String
    ) -> RequestLineContext? {
        let trimmed = line.drop(while: { $0.isWhitespace })
        guard let whitespaceIndex = trimmed.firstIndex(where: {
            $0.isWhitespace
        }) else {
            let prefix = String(trimmed)
            guard prefix.isEmpty || requestMethods.contains(where: {
                $0.rawValue.hasPrefix(prefix.uppercased())
            }) else { return nil }
            return .method(prefix: prefix)
        }

        let methodText = String(trimmed[..<whitespaceIndex]).uppercased()
        guard let method = WorkspaceRequestMethod(rawValue: methodText),
              requestMethods.contains(where: { $0 == method })
        else { return nil }
        return .path(method: method)
    }

    static func tokenRange(
        in source: NSString,
        endingAt cursor: Int
    ) -> NSRange {
        var start = cursor
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_./-*?=,%:@+")
        )
        while start > 0 {
            let scalar = UnicodeScalar(source.character(at: start - 1))
            guard let scalar, allowed.contains(scalar) else { break }
            start -= 1
        }
        return NSRange(location: start, length: cursor - start)
    }
    struct Item: Sendable {
        let label: String
        let insertionText: String
        let range: NSRange
        let selection: NSRange?
    }
    static func suggestions(source: String, cursor: Int, resources: [WorkspaceElasticsearchCompletionResource]) -> [Item] {
        let ns = source as NSString
        guard cursor >= 0, cursor <= ns.length else { return [] }
        let before = ns.substring(to: cursor) as NSString
        let start = (before as String).lastIndex(of: "\n").map { (String((before as String)[...$0]) as NSString).length } ?? 0
        let line = ns.substring(with: NSRange(location: start, length: cursor - start))
        let token = tokenRange(in: ns, endingAt: cursor)
        switch requestLineContext(line) {
        case .method(let prefix): return requestMethods.filter { $0.rawValue.hasPrefix(prefix.uppercased()) }.map { .init(label: $0.rawValue, insertionText: $0.rawValue + " ", range: token, selection: nil) }
        case .path(let method):
            let prefix = ns.substring(with: token)
            return pathSuggestions(forPathPrefix: prefix, method: method, resources: resources).map { .init(label: $0.label, insertionText: $0.insertionText, range: token, selection: $0.selectedRangeInInsertion) }
        case nil: return []
        }
    }
}
