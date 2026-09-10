import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

struct WorkspaceElasticsearchCompletionResource: Equatable, Sendable {
    let name: String
    let kind: WorkspaceDatabaseObjectKind
}

private struct WorkspaceElasticsearchCompletionEntry: CodeSuggestionEntry {
    enum Kind {
        case method
        case resource(WorkspaceDatabaseObjectKind)
        case endpoint
        case key
        case queryClause
        case field
        case value
    }

    let label: String
    let insertionText: String
    let replacementRange: NSRange
    let requestCursorLocation: Int
    let kind: Kind
    let selectedRangeInInsertion: NSRange?
    let replacementText: String?
    let previewsInsertion: Bool
    let detailOverride: String?

    init(
        label: String,
        insertionText: String,
        replacementRange: NSRange,
        requestCursorLocation: Int? = nil,
        kind: Kind,
        selectedRangeInInsertion: NSRange? = nil,
        replacementText: String? = nil,
        previewsInsertion: Bool = false,
        detailOverride: String? = nil
    ) {
        self.label = label
        self.insertionText = insertionText
        self.replacementRange = replacementRange
        self.requestCursorLocation = requestCursorLocation
            ?? NSMaxRange(replacementRange)
        self.kind = kind
        self.selectedRangeInInsertion = selectedRangeInInsertion
        self.replacementText = replacementText
        self.previewsInsertion = previewsInsertion
        self.detailOverride = detailOverride
    }

    var completionIdentity: String { "\(kind):\(label)" }
    var detail: String? {
        if let detailOverride { return detailOverride }
        return switch kind {
        case .method:
            AppCopy.current.text("HTTP 方法", "HTTP Method")
        case .resource(let kind):
            switch kind {
            case .elasticsearchIndex:
                AppCopy.current.text("索引", "Index")
            case .elasticsearchAlias:
                "Alias"
            case .elasticsearchDataStream:
                AppCopy.current.text("数据流", "Data Stream")
            case .table, .view:
                nil
            }
        case .endpoint: AppCopy.current.text("端点", "Endpoint")
        case .key: AppCopy.current.text("DSL 键", "DSL Key")
        case .queryClause: AppCopy.current.text("查询子句", "Query Clause")
        case .field: AppCopy.current.text("Mapping 字段", "Mapping Field")
        case .value: AppCopy.current.text("值", "Value")
        }
    }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { previewsInsertion ? insertionText : nil }
    var deprecated: Bool { false }
    var image: Image {
        switch kind {
        case .method: Image(systemName: "arrow.right.circle")
        case .resource(let kind): Image(systemName: kind.systemImage)
        case .endpoint: Image(systemName: "network")
        case .key: Image(systemName: "curlybraces")
        case .queryClause: Image(systemName: "line.3.horizontal.decrease")
        case .field: Image(systemName: "rectangle.grid.1x2")
        case .value: Image(systemName: "textformat")
        }
    }
    var imageColor: Color {
        switch kind {
        case .method: .purple
        case .resource(let kind):
            switch kind {
            case .elasticsearchIndex: .blue
            case .elasticsearchAlias: .orange
            case .elasticsearchDataStream: .green
            case .table, .view: .secondary
            }
        case .endpoint: .blue
        case .key: .purple
        case .queryClause: .teal
        case .field: .orange
        case .value: .secondary
        }
    }
}

@MainActor
final class WorkspaceElasticsearchCompletionService: CodeSuggestionDelegate {
    private struct Endpoint {
        let path: String
        let allowsGET: Bool
        let allowsPOST: Bool
        let supportsResource: Bool
        var allowsPUT = false
        var allowsDELETE = false
    }

    private enum RequestLineContext {
        case method(prefix: String)
        case path(method: WorkspaceRequestMethod)
    }

    private static let requestMethods: [WorkspaceRequestMethod] = [
        .get, .post, .put, .delete, .head,
    ]
    private static let endpoints = [
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
    private let fields: @MainActor (String?) async -> [String]
    private let resources: @MainActor ()
        -> [WorkspaceElasticsearchCompletionResource]
    private let indentationUnit: @MainActor () -> String
    private let dslCompletionWorker =
        WorkspaceElasticsearchDSLCompletionWorker()

    init(
        fields: @escaping @MainActor (String?) async -> [String],
        resources: @escaping @MainActor ()
            -> [WorkspaceElasticsearchCompletionResource] = { [] },
        indentationUnit: @escaping @MainActor () -> String = { "  " }
    ) {
        self.fields = fields
        self.resources = resources
        self.indentationUnit = indentationUnit
    }

    func completionTriggerCharacters() -> Set<String> {
        [" ", "\n", "/", "_", "\"", "{", "[", ",", ":"]
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let snapshot = completionSnapshot(
            textView: textView,
            cursorPosition: cursorPosition
        ) else { return nil }
        if let entries = requestLineSuggestions(snapshot: snapshot) {
            return entries.isEmpty ? nil : (cursorPosition, entries)
        }

        do {
            let resourceName = try await dslCompletionWorker.resourceName(
                source: snapshot.source,
                cursor: snapshot.cursor
            )
            try Task.checkCancellation()
            let fieldNames = await fields(resourceName)
            try Task.checkCancellation()
            let items = try await dslCompletionWorker.completions(
                source: snapshot.source,
                cursor: snapshot.cursor,
                fields: fieldNames,
                resources: resources(),
                indentationUnit: indentationUnit()
            )
            try Task.checkCancellation()
            guard textView.textView.string == snapshot.source,
                  textView.textView.selectedRange() == cursorPosition.range,
                  !textView.textView.hasMarkedText()
            else { return nil }
            let entries = items.map { item in
                WorkspaceElasticsearchCompletionEntry(
                    label: item.label,
                    insertionText: item.insertionText,
                    replacementRange: item.replacementRange,
                    requestCursorLocation: item.requestCursorLocation,
                    kind: Self.kind(for: item.kind),
                    selectedRangeInInsertion: item.selectedRangeInInsertion,
                    replacementText: (snapshot.source as NSString).substring(
                        with: item.replacementRange
                    ),
                    previewsInsertion: true
                )
            }
            return entries.isEmpty ? nil : (cursorPosition, entries)
        } catch {
            return nil
        }
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let snapshot = completionSnapshot(
            textView: textView,
            cursorPosition: cursorPosition
        ) else { return nil }
        return requestLineSuggestions(snapshot: snapshot)
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? WorkspaceElasticsearchCompletionEntry,
              let cursorPosition,
              cursorPosition.range.length == 0,
              cursorPosition.range.location == entry.requestCursorLocation,
              entry.replacementRange.location + entry.replacementRange.length
                <= textView.textView.length,
              entry.replacementText == nil
                || (textView.textView.string as NSString).substring(
                    with: entry.replacementRange
                ) == entry.replacementText,
              !textView.textView.hasMarkedText()
        else { return }
        textView.textView.undoManager?.beginUndoGrouping()
        textView.textView.replaceCharacters(
            in: entry.replacementRange,
            with: entry.insertionText
        )
        textView.textView.undoManager?.endUndoGrouping()
        if let selectedRange = entry.selectedRangeInInsertion {
            textView.textView.selectionManager.setSelectedRange(
                NSRange(
                    location: entry.replacementRange.location
                        + selectedRange.location,
                    length: selectedRange.length
                )
            )
            textView.textView.scrollSelectionToVisible()
        }
    }

    private struct CompletionSnapshot {
        let source: String
        let cursor: Int
        let beforeCursor: String
        let tokenRange: NSRange
        let prefix: String
    }

    private func completionSnapshot(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> CompletionSnapshot? {
        let cursor = cursorPosition.range.location
        guard cursor != NSNotFound,
              cursorPosition.range.length == 0,
              !textView.textView.hasMarkedText(),
              cursor <= textView.textView.length
        else { return nil }

        let source = textView.textView.string as NSString
        let lineRange = source.lineRange(
            for: NSRange(location: cursor, length: 0)
        )
        let beforeCursor = source.substring(
            with: NSRange(
                location: lineRange.location,
                length: cursor - lineRange.location
            )
        )
        let tokenRange = Self.tokenRange(in: source, endingAt: cursor)
        let prefix = source.substring(with: tokenRange)
        return CompletionSnapshot(
            source: source as String,
            cursor: cursor,
            beforeCursor: beforeCursor,
            tokenRange: tokenRange,
            prefix: prefix
        )
    }

    private func requestLineSuggestions(
        snapshot: CompletionSnapshot
    ) -> [WorkspaceElasticsearchCompletionEntry]? {
        let entries: [WorkspaceElasticsearchCompletionEntry]
        switch Self.requestLineContext(snapshot.beforeCursor) {
        case .method(let methodPrefix):
            entries = Self.requestMethods.compactMap { method in
                guard method.rawValue.hasPrefix(methodPrefix.uppercased())
                else { return nil }
                return WorkspaceElasticsearchCompletionEntry(
                    label: method.rawValue,
                    insertionText: "\(method.rawValue) ",
                    replacementRange: snapshot.tokenRange,
                    kind: .method
                )
            }
        case .path(let method):
            entries = Self.pathSuggestions(
                forPathPrefix: snapshot.prefix,
                method: method,
                resources: resources()
            ).map { suggestion in
                // Keep completed path components outside the replacement. The menu
                // describes the remaining endpoint, not the already typed resource/path.
                let parent = snapshot.prefix.lastIndex(of: "/").map {
                    String(snapshot.prefix[...$0])
                } ?? ""
                let retained = suggestion.insertionText.hasPrefix(parent) ? parent : ""
                let offset = (retained as NSString).length
                let range = NSRange(location: snapshot.tokenRange.location + offset,
                    length: snapshot.tokenRange.length - offset)
                return WorkspaceElasticsearchCompletionEntry(
                    label: suggestion.label.hasPrefix(retained)
                        ? String(suggestion.label.dropFirst(retained.count)) : suggestion.label,
                    insertionText: String(suggestion.insertionText.dropFirst(retained.count)),
                    replacementRange: range,
                    requestCursorLocation: snapshot.cursor,
                    kind: suggestion.kind,
                    selectedRangeInInsertion: suggestion.selectedRangeInInsertion.map {
                        NSRange(location: $0.location - offset, length: $0.length)
                    },
                    replacementText: (snapshot.source as NSString).substring(with: range),
                    detailOverride: suggestion.detail
                )
            }
        case nil:
            return nil
        }
        return entries
    }

    private static func kind(
        for kind: WorkspaceElasticsearchDSLCompletionKind
    ) -> WorkspaceElasticsearchCompletionEntry.Kind {
        switch kind {
        case .key: .key
        case .queryClause: .queryClause
        case .field: .field
        case .value: .value
        }
    }

    private struct PathSuggestion {
        let label: String
        let insertionText: String
        let kind: WorkspaceElasticsearchCompletionEntry.Kind
        let selectedRangeInInsertion: NSRange?
        let detail: String?

        init(
            label: String,
            insertionText: String,
            kind: WorkspaceElasticsearchCompletionEntry.Kind,
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

    private static func pathSuggestions(
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

    private static func resourceSuggestions(
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

    private static func endpointSuggestion(
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

    private static func allowedEndpoints(
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

    private static func requestLineContext(
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

    private static func tokenRange(
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
}
