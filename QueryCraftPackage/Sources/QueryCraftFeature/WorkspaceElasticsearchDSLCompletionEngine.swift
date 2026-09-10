import Foundation

enum WorkspaceElasticsearchDSLCompletionKind: Sendable {
    case key
    case queryClause
    case field
    case value
}

struct WorkspaceElasticsearchDSLCompletionItem: Sendable {
    let label: String
    let insertionText: String
    let replacementRange: NSRange
    let requestCursorLocation: Int
    let selectedRangeInInsertion: NSRange
    let kind: WorkspaceElasticsearchDSLCompletionKind
}

actor WorkspaceElasticsearchDSLCompletionWorker {
    private enum Endpoint: Equatable, Sendable {
        case search
        case count
        case analyze
        case sql
        case msearchHeader
        case mapping
        case document
        case update
        case settings
        case aliases
        case reindex
        case bulkHeader
    }

    private enum Position: Equatable, Sendable {
        case root
        case key
        case value
    }

    private struct Context: Sendable {
        let endpoint: Endpoint
        let resourceName: String?
        let position: Position
        let path: [String]
        let prefix: String
        let replacementRange: NSRange
        let existingKeys: Set<String>
        let containerIndent: String
        let lineIndent: String
        let startsImmediatelyAfterOpeningObject: Bool
        let normalizesFollowingObjectClose: Bool
        let replacesExistingKey: Bool
        let requiresSingleLine: Bool
    }

    private struct KeySpec: Sendable {
        let name: String
        let shape: ValueShape
        let kind: WorkspaceElasticsearchDSLCompletionKind

        init(
            _ name: String,
            _ shape: ValueShape,
            kind: WorkspaceElasticsearchDSLCompletionKind = .key
        ) {
            self.name = name
            self.shape = shape
            self.kind = kind
        }
    }

    private enum ValueShape: Sendable {
        case emptyObject
        case emptyArray
        case queryArray
        case string(String)
        case number(String)
        case boolean(Bool)
        case objectWithField
        case rangeObject
    }

    private struct MarkedSnippet {
        static let selectionStart = "\u{001D}"
        static let selectionEnd = "\u{001E}"

        let text: String
        let selectedRange: NSRange

        init(_ markedText: String) {
            let mutable = NSMutableString(string: markedText)
            let start = mutable.range(of: Self.selectionStart)
            let end = mutable.range(of: Self.selectionEnd)
            if start.location != NSNotFound,
               end.location != NSNotFound,
               end.location >= NSMaxRange(start)
            {
                let selectionLength = end.location - NSMaxRange(start)
                mutable.deleteCharacters(in: end)
                mutable.deleteCharacters(in: start)
                text = mutable as String
                selectedRange = NSRange(
                    location: start.location,
                    length: selectionLength
                )
            } else {
                text = mutable as String
                selectedRange = NSRange(location: mutable.length, length: 0)
            }
        }
    }

    func resourceName(
        source: String,
        cursor: Int
    ) throws -> String? {
        try analyze(
            source: source,
            cursor: cursor,
            indentationUnit: "  "
        )?.resourceName
    }

    func completions(
        source: String,
        cursor: Int,
        fields: [String],
        resources: [WorkspaceElasticsearchCompletionResource],
        indentationUnit: String
    ) throws -> [WorkspaceElasticsearchDSLCompletionItem] {
        try Task.checkCancellation()
        guard let context = try analyze(
            source: source,
            cursor: cursor,
            indentationUnit: indentationUnit
        ) else { return [] }
        let candidates: [(String, MarkedSnippet,
                          WorkspaceElasticsearchDSLCompletionKind)]
        switch context.position {
        case .root, .key:
            candidates = keyCandidates(
                context: context,
                fields: fields,
                indentationUnit: indentationUnit
            )
        case .value:
            candidates = valueCandidates(
                context: context,
                fields: fields,
                resources: resources
            )
        }
        try Task.checkCancellation()
        if context.prefix.isEmpty {
            return candidates.map { label, snippet, kind in
                WorkspaceElasticsearchDSLCompletionItem(
                    label: label,
                    insertionText: snippet.text,
                    replacementRange: context.replacementRange,
                    requestCursorLocation: cursor,
                    selectedRangeInInsertion: snippet.selectedRange,
                    kind: kind
                )
            }
        }
        var matches: [(
            label: String,
            snippet: MarkedSnippet,
            kind: WorkspaceElasticsearchDSLCompletionKind,
            match: CompletionLabelMatch,
            sequence: Int
        )] = []
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard let match = CompletionLabelMatcher.match(
                label: candidate.0,
                query: context.prefix
            ) else { continue }
            matches.append((
                candidate.0,
                candidate.1,
                candidate.2,
                match,
                index
            ))
        }
        matches.sort { lhs, rhs in
            if lhs.match.tier != rhs.match.tier {
                return lhs.match.tier < rhs.match.tier
            }
            if lhs.match.score != rhs.match.score {
                return lhs.match.score < rhs.match.score
            }
            let labelOrder = lhs.label.localizedStandardCompare(rhs.label)
            if labelOrder != .orderedSame {
                return labelOrder == .orderedAscending
            }
            return lhs.sequence < rhs.sequence
        }
        try Task.checkCancellation()
        return matches.map { candidate in
            return WorkspaceElasticsearchDSLCompletionItem(
                label: candidate.label,
                insertionText: candidate.snippet.text,
                replacementRange: context.replacementRange,
                requestCursorLocation: cursor,
                selectedRangeInInsertion: candidate.snippet.selectedRange,
                kind: candidate.kind
            )
        }
    }

    private func analyze(
        source: String,
        cursor: Int,
        indentationUnit: String
    ) throws -> Context? {
        let sourceLength = (source as NSString).length
        guard cursor >= 0, cursor <= sourceLength else { return nil }
        let parser = ElasticsearchConsoleParser()
        let parsed = try parser.request(
            in: source,
            intersecting: NSRange(location: cursor, length: 0)
        )
        guard cursor >= parsed.bodyRange.location,
              cursor <= NSMaxRange(parsed.bodyRange),
              let endpoint = Self.endpoint(for: parsed.request.path)
        else { return nil }

        let requestResource = Self.resourceName(from: parsed.request.path)
        let unit: CompletionUnit
        switch endpoint {
        case .msearchHeader, .bulkHeader:
            unit = Self.msearchUnit(
                source: source as NSString,
                bodyRange: parsed.bodyRange,
                cursor: cursor,
                requestResource: requestResource,
                bulk: endpoint == .bulkHeader
            )
        default:
            unit = CompletionUnit(
                endpoint: endpoint,
                resourceName: requestResource,
                sourceRange: parsed.bodyRange,
                requiresSingleLine: false
            )
        }
        guard cursor >= unit.sourceRange.location,
              cursor <= NSMaxRange(unit.sourceRange)
        else { return nil }
        let unitSource = (source as NSString).substring(with: unit.sourceRange)
        let relativeCursor = cursor - unit.sourceRange.location
        let scanner = JSONContextScanner(
            source: unitSource,
            cursor: relativeCursor,
            absoluteOffset: unit.sourceRange.location
        )
        guard let scanned = try scanner.scan() else { return nil }
        let position: Position = switch scanned.position {
        case .root: .root
        case .key: .key
        case .value: .value
        }
        var replacementRange = scanned.replacementRange
        let normalizesFollowingObjectClose = position == .key
            && !unit.requiresSingleLine
            && scanned.followingObjectCloseWhitespaceRange != nil
        if normalizesFollowingObjectClose,
           let whitespaceRange = scanned.followingObjectCloseWhitespaceRange,
           whitespaceRange.location == NSMaxRange(replacementRange)
        {
            replacementRange.length += whitespaceRange.length
        }
        return Context(
            endpoint: unit.endpoint,
            resourceName: unit.resourceName,
            position: position,
            path: scanned.path,
            prefix: scanned.prefix,
            replacementRange: replacementRange,
            existingKeys: scanned.existingKeys,
            containerIndent: scanned.containerIndent,
            lineIndent: scanned.lineIndent,
            startsImmediatelyAfterOpeningObject:
                scanned.startsImmediatelyAfterOpeningObject,
            normalizesFollowingObjectClose: normalizesFollowingObjectClose,
            replacesExistingKey: scanned.replacesExistingKey,
            requiresSingleLine: unit.requiresSingleLine
        )
    }

    private struct CompletionUnit {
        let endpoint: Endpoint
        let resourceName: String?
        let sourceRange: NSRange
        let requiresSingleLine: Bool
    }

    private static func endpoint(for path: String) -> Endpoint? {
        let path = path.split(separator: "?", maxSplits: 1)[0]
        let segments = path.split(separator: "/").map(String.init)
        if segments.last == "_msearch" { return .msearchHeader }
        if segments.last == "_bulk" { return .bulkHeader }
        if segments.last == "_count" { return .count }
        if segments.last == "_analyze" { return .analyze }
        if segments.last == "_sql" { return .sql }
        if segments.last == "_search" { return .search }
        if segments.last == "_mapping" { return .mapping }
        if segments.contains("_doc") || segments.contains("_create") { return .document }
        if segments.contains("_update") || segments.last == "_update_by_query" { return .update }
        if segments.last == "_delete_by_query" { return .search }
        if segments.last == "_settings" { return .settings }
        if segments.last == "_aliases" { return .aliases }
        if segments.last == "_reindex" { return .reindex }
        return nil
    }

    private static func resourceName(from path: String) -> String? {
        let path = path.split(separator: "?", maxSplits: 1)[0]
        let segments = path.split(separator: "/").map(String.init)
        guard let endpointIndex = segments.firstIndex(where: {
            $0.hasPrefix("_")
        }), endpointIndex > 0 else { return nil }
        return segments[0].removingPercentEncoding ?? segments[0]
    }

    private static func msearchUnit(
        source: NSString,
        bodyRange: NSRange,
        cursor: Int,
        requestResource: String?,
        bulk: Bool = false
    ) -> CompletionUnit {
        let relativeCursor = max(0, cursor - bodyRange.location)
        let body = source.substring(with: bodyRange) as NSString
        let boundedCursor = min(relativeCursor, body.length)
        let lineRange = body.lineRange(
            for: NSRange(location: boundedCursor, length: 0)
        )
        let contentEnd = lineRange.location + lineRange.length
            - trailingNewlineLength(in: body, range: lineRange)
        let currentRange = NSRange(
            location: bodyRange.location + lineRange.location,
            length: max(0, contentEnd - lineRange.location)
        )

        var precedingLines: [String] = []
        var position = 0
        while position < lineRange.location {
            let range = body.lineRange(
                for: NSRange(location: position, length: 0)
            )
            let end = range.location + range.length
                - trailingNewlineLength(in: body, range: range)
            let value = body.substring(with: NSRange(
                location: range.location,
                length: max(0, end - range.location)
            )).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { precedingLines.append(value) }
            guard NSMaxRange(range) > position else { break }
            position = NSMaxRange(range)
        }

        var isHeader = precedingLines.count.isMultiple(of: 2)
        var resourceName = requestResource
        var bulkAction: String?
        if bulk {
            isHeader = true
            for line in precedingLines {
                if isHeader {
                    let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                    bulkAction = object?.keys.first
                    let metadata = bulkAction.flatMap { object?[$0] as? [String: Any] }
                    resourceName = metadata?["_index"] as? String ?? requestResource
                    isHeader = bulkAction == "delete"
                } else { isHeader = true }
            }
        }
        if !bulk, !isHeader,
           let header = precedingLines.last,
           let data = header.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
           let index = object["index"] as? String
        {
            resourceName = index
        }
        return CompletionUnit(
            endpoint: bulk ? (isHeader ? .bulkHeader : bulkAction == "update" ? .update : .document) : (isHeader ? .msearchHeader : .search),
            resourceName: resourceName,
            sourceRange: currentRange,
            requiresSingleLine: true
        )
    }

    private static func trailingNewlineLength(
        in source: NSString,
        range: NSRange
    ) -> Int {
        guard range.length > 0 else { return 0 }
        let last = source.character(at: NSMaxRange(range) - 1)
        if last == 10 {
            return range.length > 1
                    && source.character(at: NSMaxRange(range) - 2) == 13
                ? 2 : 1
        }
        return last == 13 ? 1 : 0
    }

    private func keyCandidates(
        context: Context,
        fields: [String],
        indentationUnit: String
    ) -> [(String, MarkedSnippet,
           WorkspaceElasticsearchDSLCompletionKind)] {
        if isFieldKeyPath(context.path) || (context.endpoint == .document && context.path.isEmpty)
            || (context.endpoint == .update && context.path.last == "doc")
            || (context.endpoint == .mapping && ["properties", "fields"].contains(context.path.last ?? "")) {
            return fields.map { field in
                let shape: ValueShape = context.endpoint == .mapping ? .emptyObject : context.path.last == "range"
                    ? .rangeObject : .string("")
                return makeKeyCandidate(
                    label: field,
                    key: field,
                    shape: shape,
                    kind: .field,
                    context: context,
                    indentationUnit: indentationUnit
                )
            }
        }
        if isSortFieldPath(context.path) {
            return fields.map { field in
                makeKeyCandidate(
                    label: field,
                    key: field,
                    shape: .string("asc"),
                    kind: .field,
                    context: context,
                    indentationUnit: indentationUnit
                )
            }
        }
        if isAggregationNamePath(context.path) {
            return fields.map { field in
                makeAggregationCandidate(
                    field: field,
                    context: context,
                    indentationUnit: indentationUnit
                )
            }
        }

        let specs = keySpecs(endpoint: context.endpoint, path: context.path)
        return specs.compactMap { spec in
            guard !context.existingKeys.contains(spec.name) else { return nil }
            return makeKeyCandidate(
                label: spec.name,
                key: spec.name,
                shape: spec.shape,
                kind: spec.kind,
                context: context,
                indentationUnit: indentationUnit
            )
        }
    }

    private func valueCandidates(
        context: Context,
        fields: [String],
        resources: [WorkspaceElasticsearchCompletionResource]
    ) -> [(String, MarkedSnippet,
           WorkspaceElasticsearchDSLCompletionKind)] {
        guard let key = context.path.last else { return [] }
        let values: [String]
        if key == "type", context.endpoint == .mapping {
            values = WorkspaceMappingCodec.newTypes
        } else if (key == "index" || key == "_index"), [.msearchHeader, .reindex, .bulkHeader, .aliases].contains(context.endpoint) {
            values = resources.map(\.name)
        } else if ["field", "fields", "_source", "sort"].contains(key) {
            values = fields
        } else if key == "analyzer" || key == "tokenizer" {
            values = ["standard", "simple", "whitespace", "keyword"]
        } else if key == "time_zone" {
            values = ["UTC", "+08:00"]
        } else {
            return []
        }
        return values.map { value in
            let literal = Self.quoted(value)
            return (
                value,
                MarkedSnippet(literal),
                key == "index" ? .value : .field
            )
        }
    }

    private func keySpecs(endpoint: Endpoint, path: [String]) -> [KeySpec] {
        if endpoint == .bulkHeader {
            return path.isEmpty ? ["index", "create", "update", "delete"].map { KeySpec($0, .emptyObject) }
                : [KeySpec("_index", .string("")), KeySpec("_id", .string("")), KeySpec("routing", .string("")), KeySpec("if_seq_no", .number("0")), KeySpec("if_primary_term", .number("1"))]
        }
        if endpoint == .aliases, !path.isEmpty {
            if path.last == "actions" { return ["add", "remove", "remove_index"].map { KeySpec($0, .emptyObject) } }
            return [KeySpec("index", .string("")), KeySpec("alias", .string("")), KeySpec("is_write_index", .boolean(false)), KeySpec("filter", .emptyObject), KeySpec("routing", .string(""))]
        }
        if endpoint == .settings, path == ["index"] {
            return [KeySpec("number_of_replicas", .number("1")), KeySpec("refresh_interval", .string("1s")), KeySpec("blocks", .emptyObject)]
        }
        if endpoint == .mapping {
            if path.isEmpty { return [KeySpec("properties", .emptyObject), KeySpec("dynamic", .boolean(true)), KeySpec("_meta", .emptyObject)] }
            return [KeySpec("type", .string("keyword")), KeySpec("properties", .emptyObject), KeySpec("fields", .emptyObject),
                KeySpec("index", .boolean(true)), KeySpec("store", .boolean(false)), KeySpec("doc_values", .boolean(true)),
                KeySpec("ignore_above", .number("256")), KeySpec("eager_global_ordinals", .boolean(false)),
                KeySpec("coerce", .boolean(true)), KeySpec("ignore_malformed", .boolean(false)),
                KeySpec("analyzer", .string("standard")), KeySpec("normalizer", .string("")), KeySpec("format", .string("strict_date_optional_time||epoch_millis"))]
        }
        if endpoint == .update && path == ["script"] {
            return [KeySpec("source", .string("")), KeySpec("lang", .string("painless")), KeySpec("params", .emptyObject)]
        }
        if endpoint == .reindex && ["source", "dest"].contains(path.last ?? "") {
            return [KeySpec("index", .string("")), KeySpec("query", .emptyObject)]
        }
        if isQueryClausePath(path) {
            return queryClauseSpecs
        }
        if path.last == "bool" {
            return [
                KeySpec("filter", .queryArray),
                KeySpec("must", .queryArray),
                KeySpec("must_not", .queryArray),
                KeySpec("should", .queryArray),
                KeySpec("minimum_should_match", .number("1")),
            ]
        }
        if path.last == "exists" || path.last == "collapse" {
            return [KeySpec("field", .string(""))]
        }
        if isAggregationDefinitionPath(path) {
            return [
                KeySpec("terms", .objectWithField),
                KeySpec("avg", .objectWithField),
                KeySpec("sum", .objectWithField),
                KeySpec("min", .objectWithField),
                KeySpec("max", .objectWithField),
                KeySpec("date_histogram", .objectWithField),
                KeySpec("filter", .emptyObject),
                KeySpec("aggs", .emptyObject),
            ]
        }
        if isAggregationFieldDefinitionPath(path) {
            return [
                KeySpec("field", .string("")),
                KeySpec("size", .number("10")),
                KeySpec("interval", .string("1d")),
                KeySpec("calendar_interval", .string("1d")),
                KeySpec("fixed_interval", .string("1h")),
                KeySpec("missing", .string("")),
            ]
        }
        guard path.isEmpty else { return [] }
        switch endpoint {
        case .mapping, .document, .bulkHeader: return []
        case .update: return [KeySpec("doc", .emptyObject), KeySpec("script", .emptyObject), KeySpec("query", .emptyObject), KeySpec("upsert", .emptyObject), KeySpec("doc_as_upsert", .boolean(false))]
        case .settings: return [KeySpec("index", .emptyObject), KeySpec("number_of_replicas", .number("1")), KeySpec("refresh_interval", .string("1s"))]
        case .aliases: return [KeySpec("actions", .emptyArray)]
        case .reindex: return [KeySpec("source", .emptyObject), KeySpec("dest", .emptyObject), KeySpec("script", .emptyObject), KeySpec("conflicts", .string("abort"))]
        case .search:
            return searchTopLevelSpecs
        case .count:
            return [
                KeySpec("query", .emptyObject),
                KeySpec("min_score", .number("0")),
                KeySpec("terminate_after", .number("1000")),
            ]
        case .analyze:
            return [
                KeySpec("analyzer", .string("standard")),
                KeySpec("normalizer", .string("")),
                KeySpec("field", .string("")),
                KeySpec("text", .string("")),
                KeySpec("tokenizer", .string("standard")),
                KeySpec("filter", .emptyArray),
                KeySpec("char_filter", .emptyArray),
                KeySpec("explain", .boolean(true)),
                KeySpec("attributes", .emptyArray),
            ]
        case .sql:
            return [
                KeySpec("query", .string("")),
                KeySpec("params", .emptyArray),
                KeySpec("fetch_size", .number("1000")),
                KeySpec("time_zone", .string("UTC")),
                KeySpec("catalog", .string("")),
                KeySpec("columnar", .boolean(false)),
                KeySpec("field_multi_value_leniency", .boolean(false)),
                KeySpec("index_using_frozen", .boolean(false)),
                KeySpec("page_timeout", .string("45s")),
                KeySpec("request_timeout", .string("90s")),
                KeySpec("runtime_mappings", .emptyObject),
                KeySpec("filter", .emptyObject),
            ]
        case .msearchHeader:
            return [
                KeySpec("index", .string("")),
                KeySpec("routing", .string("")),
                KeySpec("preference", .string("")),
                KeySpec("search_type", .string("query_then_fetch")),
                KeySpec("request_cache", .boolean(false)),
                KeySpec("allow_no_indices", .boolean(true)),
                KeySpec("ignore_unavailable", .boolean(false)),
            ]
        }
    }

    private var searchTopLevelSpecs: [KeySpec] {
        [
            KeySpec("query", .emptyObject),
            KeySpec("post_filter", .emptyObject),
            KeySpec("aggs", .emptyObject),
            KeySpec("sort", .emptyArray),
            KeySpec("from", .number("0")),
            KeySpec("size", .number("10")),
            KeySpec("_source", .boolean(true)),
            KeySpec("fields", .emptyArray),
            KeySpec("track_total_hits", .boolean(true)),
            KeySpec("search_after", .emptyArray),
            KeySpec("highlight", .emptyObject),
            KeySpec("collapse", .objectWithField),
            KeySpec("runtime_mappings", .emptyObject),
            KeySpec("timeout", .string("30s")),
            KeySpec("terminate_after", .number("1000")),
            KeySpec("min_score", .number("0")),
        ]
    }

    private var queryClauseSpecs: [KeySpec] {
        [
            KeySpec("bool", .emptyObject, kind: .queryClause),
            KeySpec("term", .emptyObject, kind: .queryClause),
            KeySpec("terms", .emptyObject, kind: .queryClause),
            KeySpec("match", .emptyObject, kind: .queryClause),
            KeySpec("match_phrase", .emptyObject, kind: .queryClause),
            KeySpec("range", .emptyObject, kind: .queryClause),
            KeySpec("exists", .objectWithField, kind: .queryClause),
            KeySpec("multi_match", .emptyObject, kind: .queryClause),
            KeySpec("query_string", .emptyObject, kind: .queryClause),
            KeySpec("simple_query_string", .emptyObject, kind: .queryClause),
            KeySpec("prefix", .emptyObject, kind: .queryClause),
            KeySpec("wildcard", .emptyObject, kind: .queryClause),
            KeySpec("regexp", .emptyObject, kind: .queryClause),
            KeySpec("ids", .emptyObject, kind: .queryClause),
            KeySpec("nested", .emptyObject, kind: .queryClause),
            KeySpec("match_all", .emptyObject, kind: .queryClause),
        ]
    }

    private func makeKeyCandidate(
        label: String,
        key: String,
        shape: ValueShape,
        kind: WorkspaceElasticsearchDSLCompletionKind,
        context: Context,
        indentationUnit: String
    ) -> (String, MarkedSnippet,
          WorkspaceElasticsearchDSLCompletionKind) {
        let quotedKey = Self.quoted(key)
        if context.replacesExistingKey {
            return (label, MarkedSnippet(quotedKey), kind)
        }
        let propertyIndent = context.startsImmediatelyAfterOpeningObject
            ? context.containerIndent + indentationUnit
            : context.lineIndent
        let value = render(
            shape: shape,
            propertyIndent: propertyIndent,
            indentationUnit: indentationUnit,
            singleLine: context.requiresSingleLine
        )
        let pair = "\(quotedKey): \(value)"
        let marked: String
        switch context.position {
        case .root:
            if context.requiresSingleLine {
                marked = "{\(pair)}"
            } else {
                marked = "{\n\(indentationUnit)\(pair)\n}"
            }
        case .key:
            var prefix = ""
            var suffix = ""
            if context.startsImmediatelyAfterOpeningObject {
                prefix = "\n\(propertyIndent)"
            }
            if context.startsImmediatelyAfterOpeningObject
                || context.normalizesFollowingObjectClose
            {
                suffix = "\n\(context.containerIndent)"
            }
            marked = prefix + pair + suffix
        case .value:
            marked = value
        }
        return (label, MarkedSnippet(marked), kind)
    }

    private func makeAggregationCandidate(
        field: String,
        context: Context,
        indentationUnit: String
    ) -> (String, MarkedSnippet,
          WorkspaceElasticsearchDSLCompletionKind) {
        let propertyIndent = context.startsImmediatelyAfterOpeningObject
            ? context.containerIndent + indentationUnit
            : context.lineIndent
        let childIndent = propertyIndent + indentationUnit
        let valueIndent = childIndent + indentationUnit
        let pair: String
        if context.requiresSingleLine {
            pair = "\(Self.quoted(field)): {\"terms\": {\"field\": \(Self.quoted(field))}}"
        } else {
            pair = "\(Self.quoted(field)): {\n"
                + "\(childIndent)\"terms\": {\n"
                + "\(valueIndent)\"field\": \(Self.quoted(field))\n"
                + "\(childIndent)}\n\(propertyIndent)}"
        }
        let marked = pair + MarkedSnippet.selectionStart
            + MarkedSnippet.selectionEnd
        return (field, MarkedSnippet(marked), .field)
    }

    private func render(
        shape: ValueShape,
        propertyIndent: String,
        indentationUnit: String,
        singleLine: Bool
    ) -> String {
        let start = MarkedSnippet.selectionStart
        let end = MarkedSnippet.selectionEnd
        let childIndent = propertyIndent + indentationUnit
        let grandchildIndent = childIndent + indentationUnit
        switch shape {
        case .emptyObject:
            return singleLine
                ? "{\(start)\(end)}"
                : "{\n\(childIndent)\(start)\(end)\n\(propertyIndent)}"
        case .emptyArray:
            return singleLine
                ? "[\(start)\(end)]"
                : "[\n\(childIndent)\(start)\(end)\n\(propertyIndent)]"
        case .queryArray:
            return singleLine
                ? "[{\(start)\(end)}]"
                : "[\n\(childIndent){\n\(grandchildIndent)\(start)\(end)\n"
                    + "\(childIndent)}\n\(propertyIndent)]"
        case .string(let value):
            return "\"\(start)\(value)\(end)\""
        case .number(let value):
            return "\(start)\(value)\(end)"
        case .boolean(let value):
            return "\(start)\(value ? "true" : "false")\(end)"
        case .objectWithField:
            return singleLine
                ? "{\"field\": \"\(start)\(end)\"}"
                : "{\n\(childIndent)\"field\": \"\(start)\(end)\"\n"
                    + "\(propertyIndent)}"
        case .rangeObject:
            return singleLine
                ? "{\"gte\": \"\(start)\(end)\"}"
                : "{\n\(childIndent)\"gte\": \"\(start)\(end)\"\n"
                    + "\(propertyIndent)}"
        }
    }

    private func isQueryClausePath(_ path: [String]) -> Bool {
        guard let last = path.last else { return false }
        return last == "query" || last == "post_filter"
            || ["filter", "must", "must_not", "should"].contains(last)
                && path.contains("bool")
    }

    private func isFieldKeyPath(_ path: [String]) -> Bool {
        guard let last = path.last else { return false }
        return [
            "term", "terms", "match", "match_phrase", "range", "prefix",
            "wildcard", "regexp",
        ].contains(last)
    }

    private func isSortFieldPath(_ path: [String]) -> Bool {
        path.last == "sort"
    }

    private func isAggregationNamePath(_ path: [String]) -> Bool {
        path.last == "aggs" || path.last == "aggregations"
    }

    private func isAggregationDefinitionPath(_ path: [String]) -> Bool {
        guard path.count >= 2 else { return false }
        return path.dropLast().last == "aggs"
            || path.dropLast().last == "aggregations"
    }

    private func isAggregationFieldDefinitionPath(_ path: [String]) -> Bool {
        guard path.contains("aggs") || path.contains("aggregations"),
              let last = path.last
        else { return false }
        return [
            "terms", "avg", "sum", "min", "max", "date_histogram",
        ].contains(last)
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct JSONContextScanner {
    enum Position {
        case root
        case key
        case value
    }

    struct Result {
        let position: Position
        let path: [String]
        let prefix: String
        let replacementRange: NSRange
        let existingKeys: Set<String>
        let containerIndent: String
        let lineIndent: String
        let startsImmediatelyAfterOpeningObject: Bool
        let followingObjectCloseWhitespaceRange: NSRange?
        let replacesExistingKey: Bool
    }

    private enum Expectation: Equatable {
        case keyOrEnd
        case colon
        case valueOrEnd
        case commaOrEnd
    }

    private enum ContainerKind: Equatable {
        case object
        case array
    }

    private struct Frame {
        let kind: ContainerKind
        let path: [String]
        let openingLocation: Int
        var expectation: Expectation
        var pendingKey: String?
        var existingKeys: Set<String>
    }

    private let source: NSString
    private let cursor: Int
    private let absoluteOffset: Int

    init(
        source: String,
        cursor: Int,
        absoluteOffset: Int
    ) {
        self.source = source as NSString
        self.cursor = min(max(0, cursor), (source as NSString).length)
        self.absoluteOffset = absoluteOffset
    }

    func scan() throws -> Result? {
        var frames: [Frame] = []
        var rootNeedsValue = true
        var index = 0
        while index < cursor {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let character = source.character(at: index)
            if Self.isWhitespace(character) {
                index += 1
                continue
            }
            switch character {
            case 34:
                let token = stringToken(startingAt: index)
                if !token.isClosed || token.end > cursor {
                    return makeResult(
                        frames: frames,
                        rootNeedsValue: rootNeedsValue,
                        prefix: token.value,
                        replacementStart: index,
                        replacementEnd: replacementEndForString(cursor: cursor),
                        replacesExistingKey: hasColonAfterString(
                            from: cursor
                        )
                    )
                }
                consumeString(
                    token.value,
                    frames: &frames,
                    rootNeedsValue: &rootNeedsValue
                )
                index = token.end
            case 123:
                beginContainer(
                    .object,
                    openingLocation: index,
                    frames: &frames,
                    rootNeedsValue: &rootNeedsValue
                )
                index += 1
            case 91:
                beginContainer(
                    .array,
                    openingLocation: index,
                    frames: &frames,
                    rootNeedsValue: &rootNeedsValue
                )
                index += 1
            case 125, 93:
                if !frames.isEmpty { frames.removeLast() }
                index += 1
            case 58:
                if !frames.isEmpty, frames[frames.count - 1].kind == .object {
                    frames[frames.count - 1].expectation = .valueOrEnd
                }
                index += 1
            case 44:
                if !frames.isEmpty {
                    frames[frames.count - 1].expectation =
                        frames[frames.count - 1].kind == .object
                        ? .keyOrEnd : .valueOrEnd
                    frames[frames.count - 1].pendingKey = nil
                }
                index += 1
            default:
                let start = index
                while index < cursor,
                      !Self.isTokenDelimiter(source.character(at: index))
                {
                    index += 1
                }
                let token = source.substring(with: NSRange(
                    location: start,
                    length: index - start
                ))
                if index == cursor,
                   currentPosition(frames: frames, rootNeedsValue: rootNeedsValue)
                    != nil
                {
                    return makeResult(
                        frames: frames,
                        rootNeedsValue: rootNeedsValue,
                        prefix: token,
                        replacementStart: start,
                        replacementEnd: cursor,
                        replacesExistingKey: false
                    )
                }
                consumeValue(frames: &frames, rootNeedsValue: &rootNeedsValue)
            }
        }
        return makeResult(
            frames: frames,
            rootNeedsValue: rootNeedsValue,
            prefix: "",
            replacementStart: cursor,
            replacementEnd: cursor,
            replacesExistingKey: false
        )
    }

    private func makeResult(
        frames: [Frame],
        rootNeedsValue: Bool,
        prefix: String,
        replacementStart: Int,
        replacementEnd: Int,
        replacesExistingKey: Bool
    ) -> Result? {
        guard let current = currentPosition(
            frames: frames,
            rootNeedsValue: rootNeedsValue
        ) else { return nil }
        let frame = frames.last
        let path: [String]
        switch current {
        case .root:
            path = []
        case .key:
            path = frame?.path ?? []
        case .value:
            if let frame, frame.kind == .object, let key = frame.pendingKey {
                path = frame.path + [key]
            } else {
                path = frame?.path ?? []
            }
        }
        let lineRange = source.lineRange(
            for: NSRange(location: min(replacementStart, source.length), length: 0)
        )
        let beforeToken = NSRange(
            location: lineRange.location,
            length: max(0, replacementStart - lineRange.location)
        )
        let linePrefix = source.substring(with: beforeToken)
        let lineIndent = String(linePrefix.prefix(while: { $0.isWhitespace }))
        let previous = previousSignificantCharacter(before: replacementStart)
        let followingObjectCloseWhitespaceRange =
            followingObjectCloseWhitespaceRange(after: replacementEnd)
        let openingLocation = frame?.openingLocation
        return Result(
            position: current,
            path: path,
            prefix: prefix,
            replacementRange: NSRange(
                location: absoluteOffset + replacementStart,
                length: max(0, replacementEnd - replacementStart)
            ),
            existingKeys: frame?.existingKeys ?? [],
            containerIndent: openingLocation.map(lineIndentation(at:)) ?? "",
            lineIndent: lineIndent,
            startsImmediatelyAfterOpeningObject:
                current == .key
                && prefix.isEmpty
                && replacementStart == replacementEnd
                && previous == 123,
            followingObjectCloseWhitespaceRange:
                followingObjectCloseWhitespaceRange,
            replacesExistingKey: replacesExistingKey
        )
    }

    private func currentPosition(
        frames: [Frame],
        rootNeedsValue: Bool
    ) -> Position? {
        guard let frame = frames.last else {
            return rootNeedsValue ? .root : nil
        }
        switch frame.expectation {
        case .keyOrEnd:
            return frame.kind == .object ? .key : .value
        case .valueOrEnd:
            return .value
        case .colon, .commaOrEnd:
            return nil
        }
    }

    private func beginContainer(
        _ kind: ContainerKind,
        openingLocation: Int,
        frames: inout [Frame],
        rootNeedsValue: inout Bool
    ) {
        let path = valuePath(frames: frames)
        consumeValue(frames: &frames, rootNeedsValue: &rootNeedsValue)
        frames.append(Frame(
            kind: kind,
            path: path,
            openingLocation: openingLocation,
            expectation: kind == .object ? .keyOrEnd : .valueOrEnd,
            pendingKey: nil,
            existingKeys: []
        ))
    }

    private func consumeString(
        _ value: String,
        frames: inout [Frame],
        rootNeedsValue: inout Bool
    ) {
        if !frames.isEmpty,
           frames[frames.count - 1].kind == .object,
           frames[frames.count - 1].expectation == .keyOrEnd
        {
            frames[frames.count - 1].pendingKey = value
            frames[frames.count - 1].existingKeys.insert(value)
            frames[frames.count - 1].expectation = .colon
        } else {
            consumeValue(frames: &frames, rootNeedsValue: &rootNeedsValue)
        }
    }

    private func consumeValue(
        frames: inout [Frame],
        rootNeedsValue: inout Bool
    ) {
        guard !frames.isEmpty else {
            rootNeedsValue = false
            return
        }
        frames[frames.count - 1].expectation = .commaOrEnd
    }

    private func valuePath(frames: [Frame]) -> [String] {
        guard let frame = frames.last else { return [] }
        if frame.kind == .object, let key = frame.pendingKey {
            return frame.path + [key]
        }
        return frame.path
    }

    private func stringToken(
        startingAt start: Int
    ) -> (value: String, end: Int, isClosed: Bool) {
        var index = start + 1
        var escaped = false
        while index < cursor {
            let character = source.character(at: index)
            if escaped {
                escaped = false
            } else if character == 92 {
                escaped = true
            } else if character == 34 {
                let raw = source.substring(with: NSRange(
                    location: start,
                    length: index - start + 1
                ))
                return (Self.decodedString(raw), index + 1, true)
            }
            index += 1
        }
        let raw = source.substring(with: NSRange(
            location: start + 1,
            length: max(0, min(cursor, source.length) - start - 1)
        ))
        return (Self.decodedString("\"\(raw)\""), cursor, false)
    }

    private func replacementEndForString(cursor: Int) -> Int {
        var index = cursor
        var escaped = false
        while index < source.length {
            let character = source.character(at: index)
            if escaped {
                escaped = false
            } else if character == 92 {
                escaped = true
            } else if character == 34 {
                return index + 1
            } else if character == 10 || character == 13 {
                break
            }
            index += 1
        }
        return cursor
    }

    private func hasColonAfterString(from cursor: Int) -> Bool {
        let end = replacementEndForString(cursor: cursor)
        guard end > cursor else { return false }
        var index = end
        while index < source.length, Self.isWhitespace(source.character(at: index)) {
            index += 1
        }
        return index < source.length && source.character(at: index) == 58
    }

    private func previousSignificantCharacter(before location: Int) -> unichar? {
        var index = location
        while index > 0 {
            index -= 1
            let character = source.character(at: index)
            if !Self.isWhitespace(character) { return character }
        }
        return nil
    }

    private func followingObjectCloseWhitespaceRange(
        after location: Int
    ) -> NSRange? {
        var index = location
        while index < source.length,
              Self.isWhitespace(source.character(at: index))
        {
            index += 1
        }
        guard index < source.length, source.character(at: index) == 125 else {
            return nil
        }
        return NSRange(
            location: absoluteOffset + location,
            length: index - location
        )
    }

    private func lineIndentation(at location: Int) -> String {
        let lineRange = source.lineRange(
            for: NSRange(location: min(location, source.length), length: 0)
        )
        let line = source.substring(with: lineRange)
        return String(line.prefix(while: { $0.isWhitespace }))
    }

    private static func decodedString(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data)
        else {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return decoded
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isTokenDelimiter(_ character: unichar) -> Bool {
        isWhitespace(character) || [44, 58, 91, 93, 123, 125].contains(character)
    }
}
