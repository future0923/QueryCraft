import AppKit
import CodeEditTextView
import Testing
@testable import CodeEditSourceEditor
@testable import QueryCraftFeature

/// Exercises the production controller, text filters and input client without a
/// visible window, foreground activation, or events sent to the user's desktop.
@MainActor
struct SQLSnippetEditorInteractionTests {
    @Test
    func pairingAndInternalEditsKeepTheNextAndPreviousTargets() async throws {
        let editor = makeEditor()
        defer { editor.session.end() }
        let textView = editor.controller.textView!
        textView.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "\"field\" condition value END")
        #expect(editor.session.placeholderRanges == [
            SQLSourceRange(location: 0, length: 7),
            SQLSourceRange(location: 8, length: 9),
            SQLSourceRange(location: 18, length: 5),
        ])
        textView.selectionManager.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.replaceCharacters(in: NSRange(location: 3, length: 1), with: "")
        #expect(editor.session.isActive)
        #expect(editor.controller.handleEvent(event: try tabEvent()) == nil)
        #expect(textView.selectedRange() == NSRange(location: 8, length: 9))
        #expect(editor.controller.handleEvent(event: try tabEvent(modifiers: .shift)) == nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 7))
        await editor.document.close()
    }

    @Test
    func inputMethodCompositionKeepsStopsAndOwnsTabUntilCommit() async throws {
        let editor = makeEditor()
        let textView = editor.controller.textView!
        textView.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())
        #expect(editor.coordinator.claimsTextViewKeyCommand(.tab, textView: textView) == false)
        let selection = textView.selectedRange()
        #expect(editor.controller.handleEvent(event: try tabEvent()) != nil)
        #expect(textView.selectedRange() == selection)
        textView.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText() == false)
        #expect(editor.session.isActive)
        #expect(textView.string == "拼 condition value END")
        #expect(editor.controller.handleEvent(event: try tabEvent()) == nil)
        #expect(textView.selectedRange() == NSRange(location: 2, length: 9))
        await editor.document.close()
    }

    @Test
    func undoAndRedoWithinAStopKeepNavigation() async throws {
        let editor = makeEditor()
        let textView = editor.controller.textView!
        let undo = try #require(textView.undoManager)
        undo.beginUndoGrouping()
        textView.replaceCharacters(in: NSRange(location: 0, length: 5), with: "abc")
        undo.endUndoGrouping()
        undo.undo()
        #expect(textView.string == "field condition value END")
        #expect(editor.session.placeholderRanges.first == SQLSourceRange(location: 0, length: 5))
        undo.redo()
        #expect(textView.string == "abc condition value END")
        #expect(editor.session.placeholderRanges.first == SQLSourceRange(location: 0, length: 3))
        #expect(editor.controller.handleEvent(event: try tabEvent()) == nil)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 9))
        await editor.document.close()
    }

    @Test(arguments: [CompletionAcceptanceKey.tab, .returnKey, .returnOrTab])
    func navigationDoesNotChangeTheConfiguredCompletionKey(key: CompletionAcceptanceKey) async throws {
        let editor = makeEditor(completionKey: key)
        #expect(editor.controller.completionAcceptanceKey == key)
        #expect(editor.controller.coordinatorClaimsTabEvent(try tabEvent()))
        #expect(editor.controller.coordinatorClaimsTabEvent(try tabEvent(modifiers: .shift)))
        #expect(editor.controller.coordinatorClaimsTabEvent(try tabEvent(modifiers: .command)) == false)
        #expect(editor.controller.coordinatorClaimsTabEvent(try tabEvent(modifiers: [.shift, .option])) == false)
        #expect(editor.controller.handleEvent(event: try tabEvent(modifiers: .capsLock)) == nil)
        #expect(editor.controller.textView.selectedRange() == NSRange(location: 6, length: 9))
        #expect(editor.controller.handleEvent(event: try tabEvent(modifiers: [.capsLock, .shift])) == nil)
        #expect(editor.controller.textView.selectedRange() == NSRange(location: 0, length: 5))
        editor.session.end()
        #expect(editor.controller.coordinatorClaimsTabEvent(try tabEvent()) == false)
        #expect(editor.controller.completionAcceptanceKey == key)
        await editor.document.close()
    }

    @Test
    func repeatedNavigationExitsAndEscapeLeavesTheEditorReady() async throws {
        let editor = makeEditor()
        let textView = editor.controller.textView!
        for _ in 0..<3 { #expect(editor.controller.handleEvent(event: try tabEvent()) == nil) }
        #expect(editor.session.isActive == false)
        #expect(textView.selectedRange() == NSRange(location: 25, length: 0))
        #expect(editor.controller.handleEvent(event: try tabEvent()) != nil)
        editor.session.start(textView: textView, placeholderRanges: [SQLSourceRange(location: 0, length: 5)])
        #expect(editor.coordinator.handleTextViewKeyCommand(.escape, textView: textView))
        #expect(editor.session.isActive == false)
        await editor.document.close()
    }

    private func makeEditor(completionKey: CompletionAcceptanceKey = .returnOrTab) -> (
        controller: TextViewController, session: SQLSnippetSession,
        coordinator: WorkspaceQueryEditorCommandCoordinator, document: WorkspaceQueryDocumentModel
    ) {
        _ = NSApplication.shared
        let document = WorkspaceQueryDocumentModel(
            title: "Snippet test",
            configuration: DatabaseConnectionConfiguration(
                host: "127.0.0.1", port: 3306, username: "reader", password: nil,
                database: nil, tlsMode: .disabled
            ),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: [])
        )
        let session = SQLSnippetSession()
        let coordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document, languageService: WorkspaceSQLLanguageService(), snippetSession: session
        )
        let controller = TextViewController(
            string: "field condition value END", language: .sql,
            configuration: SourceEditorConfiguration(
                appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua),
                                  font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false),
                behavior: .init(completionAcceptanceKey: completionKey)
            ),
            cursorPositions: [], highlightProviders: [], coordinators: [coordinator]
        )
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        session.start(textView: controller.textView, placeholderRanges: [
            SQLSourceRange(location: 0, length: 5),
            SQLSourceRange(location: 6, length: 9),
            SQLSourceRange(location: 16, length: 5),
        ], exitLocation: 25)
        return (controller, session, coordinator, document)
    }

    private func tabEvent(modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
    }
}
