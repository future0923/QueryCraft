import AppKit
import CodeEditTextView
import Testing

@MainActor
struct EditorMultilineDeletionTests {
    @Test
    func deletingLeadingStatementsKeepsLineLayoutUsable() throws {
        for ending in ["\n", "\r\n"] {
            for trailing in [false, true] {
                let statements = (1...6).map { "ALTER TABLE test_\($0)\(ending) ADD COLUMN value_\($0) INT;" }
                let prefix = statements.prefix(3).joined(separator: ending) + ending
                let suffix = statements.suffix(3).joined(separator: ending) + (trailing ? ending : "")
                let view = TextView(string: prefix + suffix, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
                view.selectionManager.setSelectedRange(NSRange(location: 0, length: (prefix as NSString).length))
                view.deleteBackward(nil)
                #expect(view.string == suffix)
                #expect(view.layoutManager.lineStorage.length == view.textStorage.length)
                #expect(view.layoutManager.lineStorage.getLine(atOffset: 0) != nil)
                view.selectionManager.setSelectedRange(NSRange(location: 0, length: view.textStorage.length))
                view.insertText("ALTER TABLE final_table ADD COLUMN value INT;")
                #expect(view.layoutManager.lineStorage.length == view.textStorage.length)
                #expect(view.layoutManager.lineStorage.getLine(atOffset: 0) != nil)
            }
        }
    }
}
