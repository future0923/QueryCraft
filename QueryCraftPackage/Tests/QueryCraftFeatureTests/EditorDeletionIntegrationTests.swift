import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import QueryCraftFeature

@MainActor
struct EditorDeletionIntegrationTests {
    @Test
    func highlightedEditorSupportsDeletingPrefixThenReplacingSQL() async throws {
        let statements = (1...6).map { "ALTER TABLE example_\($0)\n    ADD COLUMN value_\($0) INT DEFAULT NULL\n    COMMENT '测试字段';\n" }
        let prefix = statements.prefix(3).joined(separator: "\n") + "\n"
        let suffix = statements.suffix(3).joined(separator: "\n")
        let language = WorkspaceSQLLanguageService()
        let controller = TextViewController(
            string: prefix + suffix, language: .sql,
            configuration: .init(appearance: .init(theme: WorkspaceEditorTheme.make(for: .aqua), font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [CursorPosition(range: NSRange(location: prefix.utf16.count, length: 0))],
            highlightProviders: [language], coordinators: [language]
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 320)
        controller.view.layoutSubtreeIfNeeded()
        let text = controller.textView!
        text.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 800, height: 320))
        try await Task.sleep(for: .milliseconds(100))
        text.selectionManager.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        text.moveToBeginningOfDocumentAndModifySelection(nil)
        #expect(text.selectedRange() == NSRange(location: 0, length: prefix.utf16.count))
        text.deleteBackward(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(text.string == suffix)
        try checkLayout(text)
        text.selectAll(nil)
        text.insertText("ALTER TABLE final_table\n ADD COLUMN value INT;")
        try await Task.sleep(for: .milliseconds(100))
        try checkLayout(text)
        let end = text.selectedRange().location
        text.moveLeft(nil)
        #expect(text.selectedRange().location == end - 1)
        text.moveUp(nil)
        #expect(text.selectedRange().location < end - 1)
        text.moveDown(nil)
        #expect(text.selectedRange().location == end - 1)
    }

    private func checkLayout(_ text: TextView) throws {
        text.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 800, height: 320))
        let storage = text.layoutManager.lineStorage
        #expect(storage.length == text.textStorage.length)
        #expect(storage.height > 0)
        let first = try #require(storage.getLine(atIndex: 0))
        #expect(first.range.location == 0)
        #expect(first.yPos == 0)
        #expect(first.data.lineFragments.count > 0)
        #expect(text.layoutManager.rectForOffset(0) != nil)
    }
}
