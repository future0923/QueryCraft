import AppKit
import CodeEditSourceEditor
import CodeEditTextView

@MainActor
final class WorkspaceSQLCompletionService: CodeSuggestionDelegate {
    private let languageService: WorkspaceSQLLanguageService
    private var schemaCatalog: WorkspaceSchemaCatalogSnapshot
    private let defaultDatabase: @MainActor () -> String?
    private let databaseType: @MainActor () -> DatabaseType
    private let prepareCompletionColumns: @MainActor (
        [WorkspaceSchemaObjectReference]
    ) async -> WorkspaceSchemaCatalogSnapshot
    private weak var activeTextView: TextViewController?

    init(
        languageService: WorkspaceSQLLanguageService,
        schemaCatalog: WorkspaceSchemaCatalogSnapshot,
        defaultDatabase: @escaping @MainActor () -> String?,
        prepareCompletionColumns: @escaping @MainActor (
            [WorkspaceSchemaObjectReference]
        ) async -> WorkspaceSchemaCatalogSnapshot,
        databaseType: @escaping @MainActor () -> DatabaseType = { .mysql }
    ) {
        self.languageService = languageService
        self.schemaCatalog = schemaCatalog
        self.defaultDatabase = defaultDatabase
        self.prepareCompletionColumns = prepareCompletionColumns
        self.databaseType = databaseType
    }

    func updateSchemaCatalog(_ schemaCatalog: WorkspaceSchemaCatalogSnapshot) {
        guard self.schemaCatalog.revision != schemaCatalog.revision else { return }
        self.schemaCatalog = schemaCatalog
        activeTextView?.refreshVisibleCompletions()
    }

    func completionTriggerCharacters() -> Set<String> {
        [".", "_"]
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        let range = cursorPosition.range
        guard range.location != NSNotFound, range.length == 0 else {
            return nil
        }
        guard !textView.textView.hasMarkedText() else {
            return nil
        }
        activeTextView = textView
        let requestedCatalog = schemaCatalog
        let requestedDefaultDatabase = defaultDatabase()
        let requestedDatabaseType = databaseType()
        guard var result = await languageService.completions(
            at: range.location,
            schemaCatalog: requestedCatalog,
            defaultDatabase: requestedDefaultDatabase,
            databaseType: requestedDatabaseType
        ) else {
            return nil
        }
        let loadedCatalog = await prepareCompletionColumns(
            result.referencedSchemaObjects
        )
        guard languageService.matchesCurrentSource(
            revision: result.sourceRevision,
            text: textView.textView.string
        ) else {
            return nil
        }
        if loadedCatalog.revision != requestedCatalog.revision {
            schemaCatalog = loadedCatalog
            guard let refreshedResult = await languageService.completions(
                at: range.location,
                schemaCatalog: loadedCatalog,
                defaultDatabase: requestedDefaultDatabase,
                databaseType: requestedDatabaseType
            ) else {
                return nil
            }
            guard schemaCatalog.revision == loadedCatalog.revision else {
                return nil
            }
            result = refreshedResult
        } else if requestedCatalog.revision != schemaCatalog.revision {
            return nil
        }
        guard languageService.matchesCurrentSource(
            revision: result.sourceRevision,
            text: textView.textView.string
        ) else {
            return nil
        }
        guard !result.items.isEmpty else { return nil }
        return (
            cursorPosition,
            result.items.map(WorkspaceSQLCompletionEntry.init)
        )
    }

    func completionWindowDidClose() {
        activeTextView = nil
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? WorkspaceSQLCompletionEntry,
              let cursorPosition,
              cursorPosition.range.length == 0,
              cursorPosition.range.location == entry.item.replacementRange.upperBound,
              !textView.textView.hasMarkedText(),
              languageService.matchesCurrentSource(
                revision: entry.item.sourceRevision,
                text: textView.textView.string
              ),
              entry.item.replacementRange.upperBound <= textView.textView.length
        else {
            return
        }

        textView.textView.replaceCharacters(
            in: entry.item.replacementRange.nsRange,
            with: entry.item.insertionText
        )
        if entry.item.cursorOffset != 0 {
            let insertionEnd = entry.item.replacementRange.location
                + (entry.item.insertionText as NSString).length
            textView.textView.selectionManager.setSelectedRange(
                NSRange(
                    location: insertionEnd + entry.item.cursorOffset,
                    length: 0
                )
            )
        }
    }
}
