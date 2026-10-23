import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileSQLEditorTests: XCTestCase {
    func testNativeHighlightUsesSharedPaletteWithoutChangingTextSelectionUndoOrOffset() async throws {
        let box = EditorBox("SELECT '中文😀' AS name, 42; -- comment")
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.isHidden = true; previous?.makeKey() }
        view.selectedRange = NSRange(location: (box.text as NSString).range(of: "42").location, length: 2)
        coordinator.textViewDidChangeSelection(view)
        try await wait { view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == EditorHexColor.color(EditorColorSettings()[.light].hex(for: .keyword, mode: .light)) }
        XCTAssertEqual(view.text, box.text)
        XCTAssertEqual(view.selectedRange.length, 2)
        let location = (view.text as NSString).range(of: "'中文😀'").location
        XCTAssertEqual(view.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor,
                       EditorHexColor.color(EditorColorSettings()[.light].hex(for: .string, mode: .light)))
        XCTAssertEqual(coordinator.source.text, box.text)
        XCTAssertTrue(coordinator.items.isEmpty, "A selected range must not show completions")
        coordinator.update(view, mode: .dark)
        try await wait { view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == EditorHexColor.color(EditorColorSettings()[.dark].hex(for: .keyword, mode: .dark)) }
    }

    func testCompletionInsertionHandlesUTF16MiddleCaretCursorOffsetAndNativeUndo() async throws {
        let box = EditorBox("-- 😀 中文\nSEL FROM sample"), caret = ("-- 😀 中文\nSEL" as NSString).length
        box.selection = .init(location: caret, length: 0)
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.label == "SELECT" } }
        let index = try XCTUnwrap(coordinator.items.firstIndex { $0.label == "SELECT" })
        XCTAssertTrue(coordinator.accept(index))
        XCTAssertTrue(view.text.hasPrefix("-- 😀 中文\nSELECT"))
        XCTAssertTrue(view.text.hasSuffix("FROM sample"))
        XCTAssertEqual(box.text, view.text)
        XCTAssertGreaterThanOrEqual(view.selectedRange.location, caret)
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        XCTAssertEqual(view.text, "-- 😀 中文\nSEL FROM sample", "Syntax colors must not become extra undo steps")
        coordinator.textViewDidChange(view)
        box.text = "SELECT COU"; box.selection = .init(location: box.text.utf16.count, length: 0)
        coordinator.update(view, mode: .light)
        try await wait { coordinator.items.contains { $0.label == "COUNT" } }
        let function = try XCTUnwrap(coordinator.items.firstIndex { $0.label == "COUNT" })
        XCTAssertTrue(coordinator.accept(function))
        XCTAssertTrue(view.text.contains("COUNT()"))
        XCTAssertEqual((view.text as NSString).substring(from: view.selectedRange.location), ")")
    }

    func testMarkedTextSuppressesCompletionAndCompositionSurvivesLateHighlight() async throws {
        let box = EditorBox("SEL"); box.selection = .init(location: box.text.utf16.count, length: 0)
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { !coordinator.items.isEmpty }
        view.setMarkedText("中文", selectedRange: .init(location: 2, length: 0))
        coordinator.textViewDidChange(view)
        let marked = view.text
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertEqual(view.text, marked); XCTAssertEqual(box.text, marked)
        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertFalse(view.keyCommands?.contains { $0.input == " " && $0.modifierFlags == .control } == true,
                       "IME owns completion/arrow keys while composing")
        view.unmarkText(); coordinator.textViewDidChange(view)
        try await wait { coordinator.source.text == view.text }
        XCTAssertTrue(view.text.contains("中文"))
        box.text = "SELECT 42;"; box.selection = .init(location: 7, length: 0)
        coordinator.update(view, mode: .light)
        try await wait { view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == EditorHexColor.color(EditorColorSettings()[.light].hex(for: .keyword, mode: .light)) }
        XCTAssertEqual(view.text, "SELECT 42;")
    }

    func testStaleSuggestionsCannotChangeMovedCaretOrNewTextAndCommandsRemainNative() async throws {
        let box = EditorBox("SEL"); box.selection = .init(location: 3, length: 0)
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { !coordinator.items.isEmpty }
        view.dismissCompletion?()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(coordinator.items.isEmpty, "Late metadata must not reopen Escape-dismissed candidates")
        view.requestCompletion?()
        try await wait { !coordinator.items.isEmpty }
        view.selectedRange = .init(location: 0, length: 0)
        XCTAssertFalse(coordinator.acceptSelected())
        XCTAssertEqual(view.text, "SEL")
        box.text = "SELECT 'opaque'; -- SEL"; box.selection = .init(location: box.text.utf16.count, length: 0)
        coordinator.update(view, mode: .light)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertEqual(box.text, view.text)
        XCTAssertTrue(view.keyCommands?.contains { $0.input == " " && $0.modifierFlags == .control } == true)
        XCTAssertTrue(view.keyCommands?.contains { $0.input == "\r" && $0.modifierFlags == .command } == true)
    }

    func testLongDraftHighlightsScrolledViewportWithoutMovingCaretOrChangingSource() async throws {
        let line = "SELECT '中文😀', 42; -- note\n"
        let box = EditorBox(String(repeating: line, count: 1_000))
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.isHidden = true; previous?.makeKey() }
        let keyword = EditorHexColor.color(EditorColorSettings()[.light].hex(for: .keyword, mode: .light))
        try await wait { view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == keyword }
        view.layoutIfNeeded()
        view.contentOffset = CGPoint(x: 0, y: max(0, view.contentSize.height - view.bounds.height))
        let offset = view.contentOffset, caret = view.selectedRange
        coordinator.scrollViewDidScroll(view)
        let last = box.text.utf16.count - line.utf16.count
        try await wait { view.textStorage.attribute(.foregroundColor, at: last, effectiveRange: nil) as? UIColor == keyword }
        XCTAssertGreaterThan(view.contentOffset.y, 0)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 1)
        XCTAssertEqual(view.selectedRange, caret)
        XCTAssertEqual(view.text, box.text)
        XCTAssertFalse(view.undoManager?.canUndo == true)
    }

    private func mount(_ box: EditorBox) throws -> (MobileSQLTextView, MobileSQLEditor.Coordinator, UIWindow, UIWindow?) {
        let schema = MobileSQLSchemaCatalog()
        let editor = MobileSQLEditor(text: .init(get: { box.text }, set: { box.text = $0 }),
            selection: .init(get: { box.selection }, set: { box.selection = $0 }),
            isFocused: .init(get: { box.focused }, set: { box.focused = $0 }), schema: schema, defaultDatabase: "") {}
        let coordinator = editor.makeCoordinator()
        let view = MobileSQLEditor.makeTextView(coordinator: coordinator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view.backgroundColor = .systemBackground
        host.view.addSubview(view); window.rootViewController = host; window.makeKeyAndVisible()
        view.frame = CGRect(x: 20, y: 80, width: 350, height: 180)
        coordinator.update(view, mode: .light)
        return (view, coordinator, window, previous)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

@MainActor private final class EditorBox {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var focused = false
    init(_ text: String) { self.text = text }
}
