import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Testing
@testable import QueryCraftFeature

@MainActor
struct EditorKeyboardNavigationTests {
    @Test(arguments: [UInt16(123), 124, 125, 126], [false, true])
    func sqlEditorKeepsNativeCommandArrowMovement(keyCode: UInt16, extendsSelection: Bool) throws {
        let sql = "SELECT merchant_code FROM merchant;"
        let controller = TextViewController(string: sql, language: .sql,
            configuration: .init(appearance: .init(
                theme: WorkspaceEditorTheme.make(for: .aqua),
                font: .monospacedSystemFont(ofSize: 13, weight: .regular), wrapLines: false)),
            cursorPositions: [CursorPosition(range: NSRange(location: 10, length: 0))])
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let text = try #require(controller.textView)
        window.makeFirstResponder(text)
        text.layoutManager.layoutLines(in: .init(x: 0, y: 0, width: 800, height: 220))
        text.selectionManager.setSelectedRange(NSRange(location: 10, length: 0))
        defer { window.makeFirstResponder(nil); window.contentViewController = nil; window.close() }
        let scalar: UInt32 = switch keyCode {
        case 123: 0xF702
        case 124: 0xF703
        case 125: 0xF701
        default: 0xF700
        }
        let character = String(try #require(UnicodeScalar(scalar)))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: extendsSelection ? [.command, .shift] : .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: keyCode))
        text.keyDown(with: key)
        let end = [UInt16(124), 125].contains(keyCode) ? sql.utf16.count : 0
        let expected = extendsSelection
            ? NSRange(location: min(10, end), length: abs(end - 10))
            : NSRange(location: end, length: 0)
        #expect(text.selectedRange() == expected)
        #expect(text.string == sql)
    }
}
