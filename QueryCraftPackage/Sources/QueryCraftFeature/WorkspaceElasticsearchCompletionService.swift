import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

private struct WorkspaceElasticsearchCompletionEntry: CodeSuggestionEntry {
    typealias Kind = WorkspaceElasticsearchRequestCompletion.Kind

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
        let tokenRange = WorkspaceElasticsearchRequestCompletion.tokenRange(in: source, endingAt: cursor)
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
        switch WorkspaceElasticsearchRequestCompletion.requestLineContext(snapshot.beforeCursor) {
        case .method(let methodPrefix):
            entries = WorkspaceElasticsearchRequestCompletion.requestMethods.compactMap { method in
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
            entries = WorkspaceElasticsearchRequestCompletion.pathSuggestions(
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

    static func pathSuggestionTexts(forPathPrefix prefix: String, method: WorkspaceRequestMethod, resources: [WorkspaceElasticsearchCompletionResource]) -> [String] {
        WorkspaceElasticsearchRequestCompletion.pathSuggestionTexts(forPathPrefix: prefix, method: method, resources: resources)
    }
}
