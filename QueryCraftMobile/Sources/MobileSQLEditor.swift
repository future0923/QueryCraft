import SwiftUI
import UIKit
import QueryCraftMobileTransport

/// UIKit supplies editable attributes, marked-text ranges and native undo; the
/// grammar, highlight recovery, completion context and ranking are shared with Mac.
struct MobileSQLEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var isFocused: Bool
    let schema: MobileSQLSchemaCatalog
    let defaultDatabase: String
    var executionInput: MobileSQLExecutionInput? = nil
    var snippets: [SQLSnippetCompletionSource] = []
    var snippetContext: MobileSQLSnippetContext? = nil
    var formattingContext: MobileSQLFormattingContext? = nil
    var preferences: MobileEditorPreferences = .shared
    var highlightConnection: MobileSQLConfiguration? = nil
    var effectiveHighlightContext: SQLHighlightContext {
        var context = schema.context
        if let highlightConnection, preferences.ansiQuoteConnections.contains(SQLHighlightContext.connectionKey(highlightConnection.sharedConfiguration)) { context.ansiQuotes = true }
        return context
    }
    var executeAll: (() -> Void)? = nil
    let execute: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MobileSQLTextView {
        Self.makeTextView(coordinator: context.coordinator)
    }
    @MainActor static func makeTextView(coordinator: Coordinator) -> MobileSQLTextView {
        let view = MobileSQLTextView()
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.backgroundColor = .clear
        view.autocapitalizationType = .none; view.autocorrectionType = .no
        view.spellCheckingType = .no; view.smartQuotesType = .no; view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainerInset = .init(top: 8, left: 38, bottom: 8, right: 6)
        view.keyboardDismissMode = .onDrag
        view.isFindInteractionEnabled = true
        view.accessibilityIdentifier = "sqlEditor"; view.accessibilityLabel = "SQL 编辑器"
        coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: MobileSQLTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view, mode: colorScheme == .dark ? .dark : .light)
    }
    static func dismantleUIView(_ view: MobileSQLTextView, coordinator: Coordinator) {
        coordinator.parent.executionInput?.detach(view)
        coordinator.stop(); view.resignFirstResponder(); view.delegate = nil
        view.inputAccessoryView = nil
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileSQLEditor
        private let parser: SQLStructuralParser?
        private let worker = SQLCompletionWorker()
        private(set) var source = SQLSourceSnapshot(revision: .init(0), text: "")
        private(set) var items: [SQLCompletionItem] = []
        private var parsed: Task<SQLParseSnapshot, Error>?
        private var analysis: Task<Void, Never>?
        private var focusTask: Task<Void, Never>?
        private var visibleHighlightTask: Task<Void, Never>?
        private var token = UUID()
        private var applying = false
        private var mode = EditorColorMode.light
        private var appearanceRevision = ""
        private var pendingEdit: SQLSourceEdit?
        private var publishedText = ""
        private var catalogRevision: UInt64 = 0
        private var context = SQLHighlightContext.generic
        private weak var view: MobileSQLTextView?
        private var bar: MobileSQLCompletionBar?
        private var popup: MobileSQLCompletionPopup?
        private var dockedSoftwareKeyboard = false
        private var itemsToken = UUID()
        private var itemsSelection = NSRange(location: 0, length: 0)
        private var dismissedRevision: SQLSourceRevision?
        private var dismissedSelection = NSRange(location: 0, length: 0)
        private var continuation: (text: String, selection: NSRange)?
        var formatter: any MobileSQLFormatting = MobileSQLFormatter()
        private var formattingRevision: UInt64 = 0
        private var formattingText = ""
        private var formattingSelection = NSRange(location: 0, length: 0)
        private var formattingComposing = false
        let snippetSession = SQLSnippetSession()
        private var snippetSources: [SQLSnippetCompletionSource] = []
        private var snippetText = ""

        init(_ parent: MobileSQLEditor) { self.parent = parent; parser = try? SQLStructuralParser() }

        func attach(_ view: MobileSQLTextView) {
            self.view = view; view.delegate = self
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
            parent.executionInput?.attach(view)
            parent.snippetContext?.attach(view)
            parent.formattingContext?.attach(view)
            snippetSession.didChange = { [weak self] in self?.updateSnippetPresentation() }
            view.navigateSnippet = { [weak self] delta in self?.navigateSnippet(delta) ?? false }
            view.endSnippet = { [weak self] in
                guard let self, self.snippetSession.isActive else { return false }
                self.snippetSession.end(); return true
            }
            view.acceptCompletion = { [weak self] in self?.acceptSelected() ?? false }
            view.requestCompletion = { [weak self, weak view] in
                guard let self, let view else { return }; self.dismissedRevision = nil; self.schedule(view, manual: true)
            }
            view.dismissCompletion = { [weak self, weak view] in
                guard let self, let view else { return }
                self.dismissedRevision = self.source.revision; self.dismissedSelection = view.selectedRange
                self.clearItems()
            }
            view.moveCompletion = { [weak self] delta in
                if let popup = self?.popup { popup.move(delta) } else { self?.bar?.move(delta) }
            }
            view.completionLayoutChanged = { [weak self] in self?.popup?.setNeedsLayout() }
            view.executeQuery = { [weak self] in self?.parent.execute() }
            view.executeDocument = { [weak self] in self?.parent.executeAll?() }
            view.requestFormatting = { [weak self] in self?.parent.formattingContext?.format(.selectionOrCurrentStatement) }
            view.formatSQL = { [weak self] request in
                guard let self else { throw SQLFormattingError.editorUnavailable }
                return try await self.format(request)
            }
        }

        func update(_ view: MobileSQLTextView, mode: EditorColorMode) {
            parent.executionInput?.attach(view)
            parent.snippetContext?.attach(view)
            let preferences = parent.preferences
            let appearance = String(describing: preferences.colors) + preferences.fontFamily + String(preferences.fontSize)
            let themeChanged = self.mode != mode || appearanceRevision != appearance
            appearanceRevision = appearance
            view.indentationUnit = preferences.indentationUnit
            view.completionKey = preferences.completionKey
            self.mode = mode
            let incoming = parent.text
            var changed = false
            if view.text != incoming, incoming != publishedText || view.markedTextRange == nil {
                snippetSession.end()
                applying = true
                if view.markedTextRange != nil { view.unmarkText() }
                view.text = incoming; view.selectedRange = clamped(parent.selection, length: (incoming as NSString).length)
                applying = false; publishedText = incoming; pendingEdit = nil; changed = true
            }
            if !view.isFirstResponder, view.markedTextRange == nil {
                view.selectedRange = clamped(parent.selection, length: (view.text as NSString).length)
            }
            let highlightContext = parent.effectiveHighlightContext
            let metadataChanged = catalogRevision != parent.schema.snapshot.revision || context != highlightContext || snippetSources != parent.snippets
            if snippetSources != parent.snippets { clearItems() }
            snippetSources = parent.snippets
            catalogRevision = parent.schema.snapshot.revision; context = parent.effectiveHighlightContext
            // Surfaces and visible text must use the current appearance before
            // asynchronous metadata/highlighting finishes on a first open.
            if (changed || themeChanged), view.markedTextRange == nil { apply([], range: highlightRange(view), to: view) }
            if changed || parsed == nil || themeChanged || metadataChanged { schedule(view) }
            if view.isFirstResponder != parent.isFocused {
                focusTask?.cancel()
                let focused = parent.isFocused
                focusTask = Task { @MainActor [weak self, weak view] in
                    guard !Task.isCancelled, let self, let view, self.parent.isFocused == focused else { return }
                    if focused { view.becomeFirstResponder() } else { view.resignFirstResponder() }
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            dismissedRevision = nil
            parent.isFocused = true
            if let view = textView as? MobileSQLTextView { schedule(view) }
        }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false; clearItems() }
        func textViewDidChange(_ textView: UITextView) {
            guard !applying, let view = textView as? MobileSQLTextView else { return }
            publishedText = view.text; parent.text = view.text; parent.selection = view.selectedRange
            schedule(view)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying, let view = textView as? MobileSQLTextView else { return }
            parent.selection = view.selectedRange
            view.decorations.update(view)
            schedule(view)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let view = scrollView as? MobileSQLTextView { view.decorations.update(view) }
            popup?.setNeedsLayout()
            guard !applying, let view = scrollView as? MobileSQLTextView,
                  source.text.utf16.count > 16_384, view.markedTextRange == nil,
                  let parser, let parsed else { return }
            visibleHighlightTask?.cancel()
            let source = source, range = highlightRange(view), context = context
            visibleHighlightTask = Task { [weak self, weak view] in
                do {
                    _ = try await parsed.value
                    let highlights = try await parser.highlights(in: .init(range), revision: source.revision, context: context)
                    guard !Task.isCancelled, let self, let view, self.source == source, view.text == source.text else { return }
                    self.apply(highlights, range: range, to: view)
                } catch {}
            }
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !applying else { return true }
            if text == "\n", EditorPreferenceRules.acceptsReturn(parent.preferences.completionKey), textView.markedTextRange == nil, acceptSelected() { return false }
            pendingEdit = .init(baseRevision: source.revision, replacedRange: .init(range), replacement: text)
            return true
        }

        func schedule(_ view: MobileSQLTextView, manual: Bool = false) {
            trackFormattingInput(view)
            analysis?.cancel(); token = UUID()
            let oldSnippetText = snippetText
            snippetText = view.text ?? ""
            if oldSnippetText != snippetText, snippetSession.isActive {
                // Native undo and IME edits do not always report shouldChange.
                // Translate the actual UTF-16 mutation once, before publishing
                // the next source revision, into the shared Mac session. Keep a
                // separate observed text during IME: parsing intentionally waits
                // for unmarking, while native selection callbacks may repeat.
                let old = Array(oldSnippetText.utf16), new = Array(snippetText.utf16)
                var first = 0, tail = 0
                while first < min(old.count, new.count), old[first] == new[first] { first += 1 }
                while tail < min(old.count, new.count) - first, old[old.count - tail - 1] == new[new.count - tail - 1] { tail += 1 }
                snippetSession.textDidChange(in: .init(location: first, length: old.count - first - tail), replacementLength: new.count - first - tail)
            }
            snippetSession.selectionDidChange(to: view.selectedRange)
            updateSnippetPresentation()
            if continuation?.text != view.text || continuation?.selection != view.selectedRange { continuation = nil }
            // Candidates belong to the captured text/caret. Retire stale ones
            // synchronously, before the replacement parse and debounce finish.
            if source.text != view.text || itemsSelection != view.selectedRange {
                clearItems()
            }
            guard !applying, view.markedTextRange == nil, let parser else { clearItems(); return }
            let text = view.text ?? ""
            if source.text != text || parsed == nil {
                parsed?.cancel()
                let previous = source
                source = .init(revision: .init(source.revision.rawValue + 1), text: text)
                let source = source
                let edit = pendingEdit.flatMap { edit -> SQLSourceEdit? in
                    let old = previous.text as NSString, range = edit.replacedRange.nsRange
                    guard edit.baseRevision == previous.revision, range.location >= 0, range.length >= 0,
                          NSMaxRange(range) <= old.length,
                          old.replacingCharacters(in: range, with: edit.replacement) == text else { return nil }
                    return edit
                }
                parsed = Task { try await parser.parse(source, applying: edit) }
                pendingEdit = nil
            }
            let source = source, selection = view.selectedRange, token = token, context = parent.effectiveHighlightContext, range = highlightRange(view), snippets = parent.snippets
            guard let parsed else { return }
            analysis = Task { [weak self, weak view] in
                do {
                    let snapshot = try await parsed.value
                    try Task.checkCancellation()
                    let highlights = try await parser.highlights(in: .init(range), revision: source.revision, context: context)
                    guard let self, let view, self.matches(view, source: source, selection: selection, token: token) else { return }
                    self.apply(highlights, range: range, to: view)
                    guard view.isFirstResponder, selection.length == 0 else { self.clearItems(); return }
                    if !manual { try await Task.sleep(for: .milliseconds(160)) }
                    try Task.checkCancellation()
                    var catalog = self.parent.schema.snapshot
                    var result = try await self.worker.completions(for: .init(source: source, cursorLocation: selection.location,
                        parseSnapshot: snapshot, schemaCatalog: catalog, defaultDatabase: self.parent.defaultDatabase, snippets: snippets))
                    guard self.matches(view, source: source, selection: selection, token: token) else { return }
                    self.show(result, in: view, manual: manual)
                    catalog = await self.parent.schema.load(force: manual)
                    guard self.matches(view, source: source, selection: selection, token: token) else { return }
                    result = try await self.worker.completions(for: .init(source: source, cursorLocation: selection.location,
                        parseSnapshot: snapshot, schemaCatalog: catalog, defaultDatabase: self.parent.defaultDatabase, snippets: snippets))
                    if let references = result?.referencedSchemaObjects {
                        catalog = await self.parent.schema.prepareColumns(references)
                        try Task.checkCancellation()
                        result = try await self.worker.completions(for: .init(source: source, cursorLocation: selection.location,
                            parseSnapshot: snapshot, schemaCatalog: catalog, defaultDatabase: self.parent.defaultDatabase, snippets: snippets))
                    }
                    guard self.matches(view, source: source, selection: selection, token: token) else { return }
                    self.show(result, in: view, manual: manual)
                } catch {
                    guard let self, self.token == token else { return }
                    if let view, view.text == source.text { self.apply([], range: range, to: view) }
                    self.clearItems()
                }
            }
        }

        private func matches(_ view: UITextView, source: SQLSourceSnapshot, selection: NSRange, token: UUID) -> Bool {
            !Task.isCancelled && self.token == token && self.source == source && view.text == source.text
                && view.selectedRange == selection && view.markedTextRange == nil
        }

        private func show(_ result: SQLCompletionResult?, in view: MobileSQLTextView, manual: Bool) {
            guard dismissedRevision != source.revision || dismissedSelection != view.selectedRange else { clearItems(); return }
            guard view.isFirstResponder, let result, !result.items.isEmpty else { clearItems(); return }
            let text = view.text as NSString
            let afterDot = view.selectedRange.location > 0 && text.substring(with: .init(location: view.selectedRange.location - 1, length: 1)) == "."
            guard manual || continuation != nil || result.items[0].replacementRange.length > 0 || afterDot else { clearItems(); return }
            items = result.items
            itemsToken = token
            itemsSelection = view.selectedRange
            presentItems(in: view)
        }

        @objc private func keyboardChanged(_ notification: Notification) {
            guard let view, let window = view.window,
                  let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardFrameChanged(window.convert(screenFrame, from: window.screen.coordinateSpace))
        }
        func keyboardFrameChanged(_ frame: CGRect) {
            guard let view, let window = view.window else { return }
            let visible = frame.intersection(window.bounds)
            let docked = !visible.isNull && visible.height > 160 && visible.width >= window.bounds.width * 0.8 && visible.maxY >= window.bounds.maxY - 2
            guard dockedSoftwareKeyboard != docked else { return }
            dockedSoftwareKeyboard = docked
            if !docked, items.isEmpty, view.traitCollection.userInterfaceIdiom == .pad,
               view.inputAccessoryView != nil, view.markedTextRange == nil {
                view.inputAccessoryView = nil; view.reloadInputViews()
            }
            if !items.isEmpty, source.text == view.text, itemsSelection == view.selectedRange, view.markedTextRange == nil {
                presentItems(in: view)
            }
        }
        private func presentItems(in view: MobileSQLTextView) {
            view.hasCompletions = true
            if view.traitCollection.userInterfaceIdiom == .pad && !dockedSoftwareKeyboard {
                if view.inputAccessoryView != nil { view.inputAccessoryView = nil; view.reloadInputViews() }
                if popup == nil {
                    popup = MobileSQLCompletionPopup(editor: view)
                    popup?.accept = { [weak self] index in _ = self?.accept(index) }
                    popup?.dismiss = { [weak view] in view?.dismissCompletion?() }
                }
                popup?.update(items)
                return
            }
            popup?.removeFromSuperview(); popup = nil
            if bar == nil {
                bar = MobileSQLCompletionBar(expanded: view.traitCollection.userInterfaceIdiom == .pad)
                bar?.accept = { [weak self] index in _ = self?.accept(index) }
            }
            bar?.update(items)
            if view.inputAccessoryView !== bar { view.inputAccessoryView = bar; view.reloadInputViews() }
        }

        @discardableResult func acceptSelected() -> Bool { accept(popup?.selected ?? bar?.selected ?? 0) }
        @discardableResult func accept(_ index: Int) -> Bool {
            guard let view, itemsToken == token, items.indices.contains(index) else { return false }
            let item = items[index]
            guard source.revision == item.sourceRevision, source.text == view.text,
                  SQLCompletionApplication.canApply(item, text: view.text, selection: view.selectedRange, hasMarkedText: view.markedTextRange != nil)
            else { clearItems(); return false }
            let insertion = SQLCompletionApplication.insertion(for: item, in: view.text, separateToken: true)
            applying = true
            if item.kind == .snippet { snippetSession.end() }
            view.selectedRange = item.replacementRange.nsRange
            view.insertText(insertion.text)
            view.selectedRange = clamped(insertion.selection, length: (view.text as NSString).length)
            applying = false
            publishedText = view.text; parent.text = view.text; parent.selection = view.selectedRange
            continuation = insertion.beginsNextToken ? (view.text, view.selectedRange) : nil
            pendingEdit = nil; clearItems(); schedule(view)
            if item.kind == .snippet {
                applying = true
                snippetSession.start(textView: view, placeholderRanges: item.selectionRanges,
                    exitLocation: item.replacementRange.location + item.insertionText.utf16.count)
                applying = false
                parent.selection = view.selectedRange
            }
            if !insertion.beginsNextToken {
                dismissedRevision = source.revision; dismissedSelection = view.selectedRange
            }
            return true
        }

        @discardableResult func navigateSnippet(_ delta: Int) -> Bool {
            guard let view, view.markedTextRange == nil, snippetSession.isActive else { return false }
            applying = true
            let moved = delta < 0 ? snippetSession.jumpToPreviousPlaceholder() : snippetSession.jumpToNextPlaceholder()
            applying = false
            parent.selection = view.selectedRange
            clearItems(); schedule(view)
            return moved
        }

        private func updateSnippetPresentation() {
            guard let view else { return }
            view.hasSnippetSession = snippetSession.isActive
            view.snippetHints = snippetSession.highlightedRanges
            view.snippetCurrentRange = snippetSession.currentEditingRange
            view.updateSnippetDecorations()
            parent.snippetContext?.update(session: snippetSession, composing: view.markedTextRange != nil)
        }

        func clearItems() {
            items = []
            view?.hasCompletions = false
            popup?.removeFromSuperview(); popup = nil
            guard let view, view.inputAccessoryView != nil else { return }
            if view.traitCollection.userInterfaceIdiom == .pad, dockedSoftwareKeyboard, view.isFirstResponder {
                bar?.update([])
                return
            }
            if view.markedTextRange != nil { bar?.update([]); return }
            view.inputAccessoryView = nil
            if view.isFirstResponder { view.reloadInputViews() }
        }
        func stop() { formattingRevision &+= 1; if let view { parent.formattingContext?.detach(view); view.formatSQL = nil; view.requestFormatting = nil }; NotificationCenter.default.removeObserver(self); token = UUID(); analysis?.cancel(); parsed?.cancel(); focusTask?.cancel(); visibleHighlightTask?.cancel(); snippetSession.end(); if let view { parent.snippetContext?.detach(view) }; clearItems() }

        private func trackFormattingInput(_ view: MobileSQLTextView) {
            let composing = view.markedTextRange != nil
            guard formattingText != view.text || formattingSelection != view.selectedRange || formattingComposing != composing else { return }
            formattingRevision &+= 1
            formattingText = view.text; formattingSelection = view.selectedRange; formattingComposing = composing
        }

        @discardableResult func format(_ request: SQLFormattingRequest) async throws -> Bool {
            guard let view else { throw SQLFormattingError.editorUnavailable }
            guard view.markedTextRange == nil else { throw SQLFormattingError.textCompositionActive }
            guard view.text.utf8.count <= 262_144 else { throw MobileSQLFormattingError.documentTooLarge }
            trackFormattingInput(view)
            let revision = formattingRevision
            let source = SQLSourceSnapshot(revision: .init(revision), text: view.text)
            let selection = view.selectedRange
            clearItems()
            let options = parent.preferences.formattingOptions
            let currentFormatter: any MobileSQLFormatting = formatter is MobileSQLFormatter ? MobileSQLFormatter(options: options) : formatter
            let edit = try await currentFormatter.edit(for: request, source: source, selection: selection)
            try Task.checkCancellation()
            guard self.view === view, formattingRevision == revision, view.text == source.text,
                  view.selectedRange == selection, view.markedTextRange == nil else { throw SQLFormattingError.sourceChanged }
            guard let edit else { return false }
            guard edit.sourceRevision == source.revision, edit.range.location >= 0,
                  edit.range.upperBound <= view.text.utf16.count else { throw SQLFormattingError.sourceChanged }
            snippetSession.end()
            applying = true
            view.undoManager?.beginUndoGrouping()
            view.selectedRange = edit.range.nsRange
            view.insertText(edit.replacement)
            view.undoManager?.endUndoGrouping()
            view.selectedRange = clamped(edit.selectedRange, length: view.text.utf16.count)
            applying = false
            publishedText = view.text; parent.text = view.text; parent.selection = view.selectedRange
            pendingEdit = nil; continuation = nil
            schedule(view)
            dismissedRevision = self.source.revision; dismissedSelection = view.selectedRange
            view.scrollRangeToVisible(view.selectedRange)
            return true
        }

        private func highlightRange(_ view: UITextView) -> NSRange {
            let count = (view.text as NSString).length
            guard count > 16_384, view.bounds.height > 0,
                  let start = view.closestPosition(to: CGPoint(x: view.textContainerInset.left, y: view.bounds.minY)),
                  let end = view.closestPosition(to: CGPoint(x: view.bounds.maxX, y: view.bounds.maxY)) else {
                return (view.text as NSString).rangeOfComposedCharacterSequences(for: .init(location: 0, length: min(count, 16_384)))
            }
            let first = max(0, view.offset(from: view.beginningOfDocument, to: start) - 256)
            let last = min(count, view.offset(from: view.beginningOfDocument, to: end) + 256)
            return (view.text as NSString).rangeOfComposedCharacterSequences(for: .init(location: first, length: max(0, last - first)))
        }

        private func apply(_ highlights: [SQLSyntaxHighlight], range: NSRange, to view: UITextView) {
            guard view.markedTextRange == nil else { return }
            let palette = parent.preferences.colors[mode]
            let font = parent.preferences.font
            let selection = view.selectedRange, offset = view.contentOffset
            let undo = view.undoManager, registersUndo = view.undoManager?.isUndoRegistrationEnabled == true
            if registersUndo { undo?.disableUndoRegistration() }
            defer { if registersUndo { undo?.enableUndoRegistration() } }
            applying = true
            view.backgroundColor = EditorHexColor.color(palette.hex(for: .background, mode: mode))
            view.tintColor = EditorHexColor.color(palette.hex(for: .cursor, mode: mode))
            view.textStorage.beginEditing()
            view.textStorage.setAttributes([.font: font, .foregroundColor: EditorHexColor.color(palette.hex(for: .text, mode: mode))], range: range)
            for highlight in highlights where highlight.range.upperBound <= view.textStorage.length {
                let role: EditorColorRole = switch highlight.kind {
                case .keyword: .keyword; case .comment: .comment; case .variable: .variable
                case .property: .property; case .function: .function; case .number: .number
                case .string: .string; case .type: .object; case .parameter: .parameter
                case .boolean: .boolean; case .attribute: .attribute; case .builtinType: .type
                case .operator: .operator; case .punctuation: .punctuation
                }
                var selectedFont = font
                let traits: UIFontDescriptor.SymbolicTraits = role == .keyword && palette.boldKeywords ? .traitBold : (role == .comment && palette.italicComments ? .traitItalic : [])
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { selectedFont = .init(descriptor: descriptor, size: font.pointSize) }
                view.textStorage.addAttributes([.font: selectedFont, .foregroundColor: EditorHexColor.color(palette.hex(for: role, mode: mode))], range: highlight.range.nsRange)
            }
            // Explicitly retain the system color-emoji fallback for composed
            // emoji runs. Monospaced font descriptors can otherwise leave a
            // missing-glyph box after UIKit attribute replacement.
            let emojiFontNames = ["AppleColorEmoji", "AppleColorEmojiUI", ".AppleColorEmojiUI"] + UIFont.familyNames.filter { $0.localizedCaseInsensitiveContains("emoji") }.flatMap { UIFont.fontNames(forFamilyName: $0) }
            if let emojiFont = emojiFontNames.lazy.compactMap({ UIFont(name: $0, size: font.pointSize) }).first {
                var cursor = range.location
                for character in (view.text as NSString).substring(with: range) {
                    let length = String(character).utf16.count
                    if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
                        view.textStorage.addAttribute(.font, value: emojiFont, range: NSRange(location: cursor, length: length))
                    }
                    cursor += length
                }
            }
            view.textStorage.endEditing(); view.selectedRange = selection; view.setContentOffset(offset, animated: false)
            view.typingAttributes = [.font: font, .foregroundColor: EditorHexColor.color(palette.hex(for: .text, mode: mode))]
            if let editor = view as? MobileSQLTextView {
                editor.decorations.isConfigured = true; editor.decorations.palette = palette; editor.decorations.mode = mode; editor.decorations.update(editor)
            }
            applying = false
        }

        private func clamped(_ range: NSRange, length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            return .init(location: location, length: min(max(0, range.length), length - location))
        }
    }
}

@MainActor final class MobileSQLTextView: UITextView {
    let decorations = MobileEditorDecorations()
    var navigateSnippet: ((Int) -> Bool)?
    var endSnippet: (() -> Bool)?
    var hasSnippetSession = false
    var snippetHints: [SQLSourceRange] = []
    var snippetCurrentRange: SQLSourceRange?
    private let snippetHintsLayer = CAShapeLayer()
    private let snippetCurrentLayer = CAShapeLayer()
    var acceptCompletion: (() -> Bool)?
    var requestCompletion: (() -> Void)?
    var dismissCompletion: (() -> Void)?
    var moveCompletion: ((Int) -> Void)?
    var executeQuery: (() -> Void)?
    var executeDocument: (() -> Void)?
    var formatSQL: ((SQLFormattingRequest) async throws -> Bool)?
    var requestFormatting: (() -> Void)?
    var indentationUnit = "    "
    var completionKey = EditorCompletionKey.returnOrTab
    var hasCompletions = false
    var completionLayoutChanged: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        decorations.update(self)
        completionLayoutChanged?()
        updateSnippetDecorations()
    }

    func updateSnippetDecorations() {
        if snippetHintsLayer.superlayer == nil { layer.addSublayer(snippetHintsLayer); layer.addSublayer(snippetCurrentLayer) }
        let dark = traitCollection.userInterfaceStyle == .dark
        snippetHintsLayer.fillColor = UIColor.label.withAlphaComponent(dark ? 0.16 : 0.1).resolvedColor(with: traitCollection).cgColor
        snippetCurrentLayer.fillColor = UIColor.clear.cgColor
        snippetCurrentLayer.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        snippetCurrentLayer.lineWidth = 1
        func path(_ ranges: [SQLSourceRange]) -> CGPath {
            let path = UIBezierPath()
            for range in ranges where range.length > 0 && range.upperBound <= (text as NSString).length {
                guard let start = position(from: beginningOfDocument, offset: range.location),
                      let end = position(from: start, offset: range.length), let textRange = textRange(from: start, to: end) else { continue }
                for selection in selectionRects(for: textRange) where selection.rect.width > 0 {
                    path.append(UIBezierPath(roundedRect: selection.rect.insetBy(dx: -1, dy: -1), cornerRadius: 3))
                }
            }
            return path.cgPath
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        snippetHintsLayer.path = path(snippetHints)
        snippetCurrentLayer.path = path(snippetCurrentRange.map { [$0] } ?? [])
        CATransaction.commit()
    }

    override var keyCommands: [UIKeyCommand]? {
        if markedTextRange != nil {
            return [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(run))] + (super.keyCommands ?? [])
        }
        return [UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(complete)),
         UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(run)),
         UIKeyCommand(input: "\r", modifierFlags: [.command, .shift], action: #selector(runDocument)),
         UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(formatCurrent)),
         UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tab)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
            + (hasSnippetSession ? [UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(backtab))] : [])
            + (!hasCompletions ? [] : [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(selectPreviousCompletion)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(selectNextCompletion))])
            + (super.keyCommands ?? [])
    }
    @objc private func formatCurrent() { guard markedTextRange == nil else { return }; requestFormatting?() }
    @objc private func complete() { requestCompletion?() }
    @objc private func runDocument() { if markedTextRange != nil { unmarkText() } else { executeDocument?() } }
    @objc private func run() { if markedTextRange != nil { unmarkText() } else { executeQuery?() } }
    @objc private func tab() { if navigateSnippet?(1) != true { if !EditorPreferenceRules.acceptsTab(completionKey) || acceptCompletion?() != true { insertText(indentationUnit) } } }
    @objc private func backtab() { _ = navigateSnippet?(-1) }
    @objc private func escape() { if hasCompletions { dismissCompletion?() } else if endSnippet?() != true { resignFirstResponder() } }
    @objc private func selectPreviousCompletion() { moveCompletion?(-1) }
    @objc private func selectNextCompletion() { moveCompletion?(1) }
}

@MainActor final class MobileSQLCompletionBar: UIInputView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let collection: UICollectionView
    private var items: [SQLCompletionItem] = []
    private(set) var selected = 0
    var accept: ((Int) -> Void)?
    private let expanded: Bool
    init(expanded: Bool = false) {
        self.expanded = expanded
        let layout = UICollectionViewFlowLayout(); layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 4; layout.sectionInset = .init(top: 4, left: 8, bottom: 4, right: 8)
        collection = .init(frame: .zero, collectionViewLayout: layout)
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: expanded ? 76 : 44), inputViewStyle: .keyboard)
        allowsSelfSizing = expanded
        backgroundColor = .secondarySystemBackground; isOpaque = true
        collection.backgroundColor = .secondarySystemBackground; collection.isOpaque = true
        collection.dataSource = self; collection.delegate = self
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "completion")
        collection.accessibilityIdentifier = "sqlCompletions"
        collection.frame = bounds; collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.showsHorizontalScrollIndicator = expanded; addSubview(collection)
        let separator = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        separator.backgroundColor = .separator; separator.autoresizingMask = .flexibleWidth
        separator.isUserInteractionEnabled = false; addSubview(separator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { .init(width: UIView.noIntrinsicMetric, height: expanded ? 76 : 44) }
    func update(_ items: [SQLCompletionItem]) { self.items = items; selected = 0; collection.reloadData() }
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }; selected = (selected + delta + items.count) % items.count
        collection.reloadData(); collection.scrollToItem(at: .init(item: selected, section: 0), at: .centeredHorizontally, animated: false)
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "completion", for: indexPath), item = items[indexPath.item]
        var content = UIListContentConfiguration.cell(); content.text = item.label
        if expanded { content.secondaryText = item.detail; content.secondaryTextProperties.font = .systemFont(ofSize: 11); content.secondaryTextProperties.numberOfLines = 1 }
        content.textProperties.font = .monospacedSystemFont(ofSize: expanded ? 15 : 13, weight: .medium)
        content.textProperties.color = .label
        content.textProperties.numberOfLines = expanded ? 2 : 1; content.directionalLayoutMargins = .init(top: 0, leading: 8, bottom: 0, trailing: 8)
        cell.contentConfiguration = content
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = indexPath.item == selected ? MobileAppearance.selectionColor : .clear
        background.cornerRadius = 8; cell.backgroundConfiguration = background
        cell.isAccessibilityElement = true; cell.accessibilityLabel = item.label; cell.accessibilityHint = item.detail
        cell.accessibilityTraits = .button
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { accept?(indexPath.item) }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        .init(width: expanded ? 260 : min(240, max(60, (items[indexPath.item].label as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)]).width + 20)), height: expanded ? 64 : 36)
    }
}
