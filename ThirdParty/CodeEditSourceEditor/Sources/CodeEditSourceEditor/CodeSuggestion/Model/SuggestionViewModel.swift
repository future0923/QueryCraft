//
//  SuggestionViewModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit

@MainActor
final class SuggestionViewModel {
    /// The items to be displayed in the window
    private(set) var items: [CodeSuggestionEntry] = []
    var itemsRequestTask: Task<Void, Never>?
    private var itemsRequestID: UUID?
    weak var activeTextView: TextViewController?

    weak var delegate: CodeSuggestionDelegate?

    private var syntaxHighlightedCache: [Int: NSAttributedString] = [:]

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        showWindowOnParent: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        requestCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: { },
            itemsLoaded: showWindowOnParent
        )
    }

    func refreshCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        itemsUnavailable: @escaping @MainActor () -> Void,
        itemsLoaded: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        requestCompletions(
            textView: textView,
            delegate: delegate,
            cursorPosition: cursorPosition,
            itemsUnavailable: itemsUnavailable,
            itemsLoaded: itemsLoaded
        )
    }

    private func requestCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        itemsUnavailable: @escaping @MainActor () -> Void,
        itemsLoaded: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        itemsRequestTask?.cancel()
        guard let targetParentWindow = textView.view.window else {
            itemsUnavailable()
            return
        }

        activeTextView = textView
        self.delegate = delegate
        let requestID = UUID()
        itemsRequestID = requestID
        itemsRequestTask = Task {
            defer { finishRequest(requestID) }
            do {
                let completionItems = await delegate.completionSuggestionsRequested(
                    textView: textView,
                    cursorPosition: cursorPosition
                )

                try Task.checkCancellation()
                guard itemsRequestID == requestID,
                      activeTextView === textView,
                      textView.view.window === targetParentWindow,
                      textView.textView.selectedRange() == cursorPosition.range,
                      !textView.textView.hasMarkedText()
                else {
                    return
                }

                guard let completionItems, !completionItems.items.isEmpty else {
                    itemsUnavailable()
                    return
                }

                textView.textView.layoutSubtreeIfNeeded()
                guard let resolvedPosition = textView.resolveCursorPosition(
                    completionItems.windowPosition
                ),
                      let localCursorRect = textView.textView.layoutManager.rectForOffset(
                        resolvedPosition.range.location
                      ),
                      let cursorRect = textView.view.window?.convertToScreen(
                        textView.textView.convert(localCursorRect, to: nil)
                      )
                else {
                    return
                }

                items = completionItems.items
                syntaxHighlightedCache = [:]
                itemsLoaded(targetParentWindow, cursorRect)
            } catch {
                return
            }
        }
    }

    private func finishRequest(_ requestID: UUID) {
        guard itemsRequestID == requestID else { return }
        itemsRequestTask = nil
        itemsRequestID = nil
    }

    @discardableResult
    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition,
        close: () -> Void
    ) -> Bool {
        if itemsRequestTask != nil {
            close()
            return false
        }

        if activeTextView !== textView {
            close()
            return false
        }

        guard let newItems = delegate.completionOnCursorMove(
            textView: textView,
            cursorPosition: position
        ),
              !newItems.isEmpty else {
            close()
            return false
        }

        items = newItems
        syntaxHighlightedCache = [:]
        return true
    }

    func didSelect(item: CodeSuggestionEntry) {
        delegate?.completionWindowDidSelect(item: item)
    }

    func applySelectedItem(item: CodeSuggestionEntry) {
        guard let activeTextView else {
            return
        }
        self.delegate?.completionWindowApplyCompletion(
            item: item,
            textView: activeTextView,
            cursorPosition: CursorPosition(
                range: activeTextView.textView.selectedRange()
            )
        )
    }

    func willClose() {
        itemsRequestTask?.cancel()
        itemsRequestTask = nil
        itemsRequestID = nil
        delegate?.completionWindowDidClose()
        items.removeAll()
        activeTextView = nil
        delegate = nil
    }

    func syntaxHighlights(forIndex index: Int) -> NSAttributedString? {
        if let cached = syntaxHighlightedCache[index] {
            return cached
        }

        if let sourcePreview = items[index].sourcePreview,
           let theme = activeTextView?.theme,
           let font = activeTextView?.font,
           let language = activeTextView?.language {
            let string = TreeSitterClient.quickHighlight(
                string: sourcePreview,
                theme: theme,
                font: font,
                language: language
            )
            syntaxHighlightedCache[index] = string
            return string
        }

        return nil
    }
}
