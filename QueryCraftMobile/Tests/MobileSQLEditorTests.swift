import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
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
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(coordinator.items.isEmpty, "Accepting a function must not reopen its old prefix or steal its argument caret")
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
        view.dismissCompletion?()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(coordinator.items.isEmpty, "A pending manual request must respect subsequent dismissal")
        view.requestCompletion?()
        try await wait { !coordinator.items.isEmpty }
        view.selectedRange = .init(location: 0, length: 0)
        XCTAssertFalse(coordinator.acceptSelected())
        XCTAssertEqual(view.text, "SEL")
        box.text = "SELECT 'opaque'; -- SEL"; box.selection = .init(location: box.text.utf16.count, length: 0)
        coordinator.update(view, mode: .light)
        XCTAssertTrue(coordinator.items.isEmpty, "Old candidates must disappear before the new parse finishes")
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

    func testCompletionPlacementStaysInWindowAndAvoidsDockedFloatingKeyboard() throws {
        for bounds in [CGRect(x: 0, y: 24, width: 1024, height: 1310), CGRect(x: 0, y: 24, width: 1366, height: 960), CGRect(x: 0, y: 24, width: 430, height: 720)] {
            let editor = CGRect(x: bounds.width > 800 ? 300 : 16, y: 90, width: bounds.width > 800 ? bounds.width - 320 : bounds.width - 32, height: 180)
            let caret = CGRect(x: editor.minX + 30, y: 150, width: 2, height: 20)
            for keyboard in [CGRect.null, CGRect(x: 0, y: bounds.maxY - 330, width: bounds.width, height: 330), CGRect(x: editor.minX + 80, y: 210, width: 280, height: 240)] {
                let frame = try XCTUnwrap(MobileSQLCompletionLayout.frame(in: bounds, editor: editor, caret: caret, keyboard: keyboard.isNull ? nil : keyboard, count: 30))
                XCTAssertTrue(bounds.contains(frame)); XCTAssertFalse(frame.intersects(caret))
                if !keyboard.isNull { XCTAssertFalse(frame.intersects(keyboard)) }
                XCTAssertGreaterThanOrEqual(frame.height, 64)
                XCTAssertLessThan(frame.minY, bounds.midY, "Candidates should stay near the editor")
            }
        }
    }

    func testPadPopupIsNearCaretScrollableAndRemovedOnDismissal() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let box = EditorBox("SEL"); box.selection = .init(location: 3, length: 0)
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.label == "SELECT" } }
        // Geometry is injected below; do not mix the simulator's currently
        // attached software keyboard notifications into this transition test.
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.keyboardFrameChanged(.zero)
        XCTAssertNil(view.inputAccessoryView)
        let popup = try XCTUnwrap(window.subviews.compactMap { $0 as? MobileSQLCompletionPopup }.first)
        let candidates = (0..<30).map { index in SQLCompletionItem(label: "column_\(index)", insertionText: "column_\(index)", detail: "真实字段注释", kind: .column, replacementRange: .init(location: 0, length: 3), sourceRevision: .init(1), cursorOffset: 0, selectionRanges: []) }
        popup.update(candidates)
        popup.keyboardFrameInWindow = CGRect(x: 0, y: window.bounds.maxY - 330, width: window.bounds.width, height: 330)
        popup.layoutIfNeeded()
        XCTAssertTrue(window.bounds.contains(popup.candidateFrame))
        XCTAssertFalse(popup.candidateFrame.intersects(try XCTUnwrap(popup.keyboardFrameInWindow)))
        popup.move(29)
        let table = try XCTUnwrap(popup.subviews.compactMap { $0 as? UITableView }.first)
        table.layoutIfNeeded()
        XCTAssertTrue(table.indexPathsForVisibleRows?.contains(IndexPath(row: 29, section: 0)) == true)
        var accepted: Int?
        popup.accept = { accepted = $0 }
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 29, section: 0))
        XCTAssertEqual(accepted, 29)
        XCTAssertFalse(popup.point(inside: CGPoint(x: 2, y: 2), with: nil))
        view.dismissCompletion?()
        XCTAssertNil(popup.superview); XCTAssertFalse(view.hasCompletions)
        XCTAssertTrue(view.isFirstResponder)
    }

    func testPadDockedKeyboardUsesStableTouchShelfAndSwitchesBackForHardware() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let box = EditorBox("SEL"); box.selection = .init(location: 3, length: 0)
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.label == "SELECT" } }
        coordinator.keyboardFrameChanged(CGRect(x: 0, y: window.bounds.maxY - 300, width: window.bounds.width, height: 300))
        let shelf = try XCTUnwrap(view.inputAccessoryView as? MobileSQLCompletionBar)
        NotificationCenter.default.removeObserver(coordinator)
        XCTAssertEqual(shelf.intrinsicContentSize.height, 76)
        let collection = try XCTUnwrap(shelf.subviews.compactMap { $0 as? UICollectionView }.first)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertEqual(shelf.backgroundColor?.resolvedColor(with: traits).cgColor.alpha, 1)
            XCTAssertEqual(collection.backgroundColor?.resolvedColor(with: traits).cgColor.alpha, 1)
        }
        XCTAssertTrue(shelf.isOpaque); XCTAssertTrue(collection.isOpaque)
        XCTAssertTrue(window.subviews.compactMap { $0 as? MobileSQLCompletionPopup }.isEmpty)
        view.dismissCompletion?()
        XCTAssertTrue(view.inputAccessoryView === shelf, "Typing/metadata updates must not move the keyboard shelf")
        XCTAssertFalse(view.hasCompletions)
        coordinator.keyboardFrameChanged(.zero)
        XCTAssertNil(view.inputAccessoryView, "An empty software shelf must not remain at the hardware-keyboard screen bottom")
        view.requestCompletion?()
        try await wait { !coordinator.items.isEmpty }
        coordinator.keyboardFrameChanged(.zero)
        XCTAssertNil(view.inputAccessoryView)
        XCTAssertFalse(window.subviews.compactMap { $0 as? MobileSQLCompletionPopup }.isEmpty)
        XCTAssertTrue(coordinator.acceptSelected()); XCTAssertTrue(view.text.hasPrefix("SELECT"))
    }

    func testAcceptedTokensAdvanceThroughSharedNextContextWithoutRepeatingOldSuggestions() async throws {
        let schema = MobileSQLSchemaCatalog(service: CompletionCatalog())
        schema.configure(.init(host: "fixture", port: 3306, username: "fixture", password: "", database: "proof", tlsMode: .disabled))
        _ = await schema.load()
        let box = EditorBox("SELECT * FR"); box.selection = .init(location: box.text.utf16.count, length: 0)
        let (view, coordinator, window, previous) = try mount(box, schema: schema, defaultDatabase: "proof")
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.label == "FROM" } }
        if view.traitCollection.userInterfaceIdiom == .pad {
            NotificationCenter.default.removeObserver(coordinator)
            coordinator.keyboardFrameChanged(CGRect(x: 0, y: window.bounds.maxY - 300, width: window.bounds.width, height: 300))
        }
        let shelf = try XCTUnwrap(view.inputAccessoryView as? MobileSQLCompletionBar)
        let collection = try XCTUnwrap(shelf.subviews.compactMap { $0 as? UICollectionView }.first)
        let from = try XCTUnwrap(coordinator.items.firstIndex { $0.label == "FROM" })
        collection.delegate?.collectionView?(collection, didSelectItemAt: .init(item: from, section: 0))
        XCTAssertEqual(view.text, "SELECT * FROM ")
        XCTAssertTrue(coordinator.items.isEmpty, "Retire the accepted candidate synchronously")
        try await wait { coordinator.items.contains { $0.label == "sample" } }
        XCTAssertFalse(coordinator.items.contains { $0.label == "FROM" })
        XCTAssertTrue(coordinator.items.allSatisfy { $0.replacementRange.nsRange == view.selectedRange })
        XCTAssertTrue(coordinator.accept(try XCTUnwrap(coordinator.items.firstIndex { $0.label == "sample" })))
        XCTAssertEqual(view.text, "SELECT * FROM sample ")
        try await wait { coordinator.items.contains { $0.label == "WHERE" } }
        XCTAssertFalse(coordinator.items.contains { $0.label == "sample" })
        XCTAssertTrue(coordinator.accept(try XCTUnwrap(coordinator.items.firstIndex { $0.label == "WHERE" })))
        try await wait { coordinator.items.contains { $0.label == "id" } }
        XCTAssertEqual(view.text, "SELECT * FROM sample WHERE ")
        view.dismissCompletion?()
        coordinator.update(view, mode: .dark)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(coordinator.items.isEmpty, "Metadata/theme refresh must not reopen a dismissed continuation")
        box.text = "SEL"; box.selection = .init(location: 3, length: 0)
        coordinator.update(view, mode: .light)
        try await wait { coordinator.items.contains { $0.label == "SELECT" } }
        XCTAssertTrue(coordinator.accept(try XCTUnwrap(coordinator.items.firstIndex { $0.label == "SELECT" })))
        XCTAssertEqual(view.text, "SELECT ")
        try await wait { coordinator.items.contains { $0.label == "FROM" } }
        XCTAssertFalse(coordinator.items.contains { $0.label == "SELECT" })
        view.undoManager?.undo()
        XCTAssertEqual(view.text, "SEL", "Token and separator form one native undo step")
    }

    func testAcceptanceAtPunctuationKeepsCaretAndDoesNotReopenCompletedToken() async throws {
        let box = EditorBox("SEL;"); box.selection = .init(location: 3, length: 0)
        let (view, coordinator, window, previous) = try mount(box)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.label == "SELECT" } }
        XCTAssertTrue(coordinator.accept(try XCTUnwrap(coordinator.items.firstIndex { $0.label == "SELECT" })))
        XCTAssertEqual(view.text, "SELECT;"); XCTAssertEqual(view.selectedRange.location, 6)
        coordinator.update(view, mode: .dark)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(coordinator.items.isEmpty)
        view.requestCompletion?()
        try await wait { !coordinator.items.isEmpty }
    }

    func testSnippetExpansionSelectsTheSharedUTF16PlaceholderAndUndoesInOneStep() async throws {
        let original = "-- 😀 中文\nsel", box = EditorBox("-- 😀 中文\nsel")
        box.selection = .init(location: original.utf16.count, length: 0)
        let controls = MobileSQLSnippetContext()
        let (view, coordinator, window, previous) = try mount(box, snippets: SQLSnippetStore.shared.completionSources, snippetContext: controls)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.kind == .snippet } }
        let index = try XCTUnwrap(coordinator.items.firstIndex { $0.kind == .snippet })
        let item = coordinator.items[index]
        XCTAssertEqual(item.label, "select *")
        XCTAssertTrue(coordinator.accept(index))
        XCTAssertEqual(view.text, "-- 😀 中文\nSELECT *\nFROM table\nLIMIT 100;")
        XCTAssertEqual(view.selectedRange, try XCTUnwrap(item.selectionRanges.first).nsRange)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "table")
        XCTAssertTrue(controls.isActive); XCTAssertEqual(controls.count, 1)
        XCTAssertTrue(view.keyCommands?.contains { $0.input == "\t" && $0.modifierFlags == .shift } == true)
        try await Task.sleep(for: .milliseconds(220)); XCTAssertTrue(coordinator.items.isEmpty)
        view.undoManager?.undo(); coordinator.textViewDidChange(view)
        XCTAssertEqual(view.text, original); XCTAssertFalse(controls.isActive)
    }

    func testSnippetTouchNavigationTracksEditsEmptyStopsBacktabAndExit() async throws {
        let box = EditorBox("cte"); box.selection = .init(location: 3, length: 0)
        let controls = MobileSQLSnippetContext()
        let (view, coordinator, window, previous) = try mount(box, snippets: SQLSnippetStore.shared.completionSources, snippetContext: controls)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.kind == .snippet } }
        XCTAssertTrue(coordinator.accept(try XCTUnwrap(coordinator.items.firstIndex { $0.kind == .snippet })))
        XCTAssertEqual(controls.count, 4)
        view.insertText("最近用户😀"); coordinator.textViewDidChange(view)
        XCTAssertEqual(coordinator.snippetSession.placeholderRanges.first?.length, "最近用户😀".utf16.count)
        controls.move(1)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "columns")
        XCTAssertEqual(controls.currentIndex, 1)
        view.deleteBackward(); coordinator.textViewDidChange(view)
        XCTAssertEqual(coordinator.snippetSession.placeholderRanges[1].length, 0)
        XCTAssertTrue(controls.isActive)
        controls.move(1)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "table")
        controls.move(-1); XCTAssertEqual(view.selectedRange.length, 0)
        view.insertText("id, name"); coordinator.textViewDidChange(view)
        controls.move(-1)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "最近用户😀")
        controls.move(-1)
        XCTAssertEqual(controls.currentIndex, 3)
        controls.move(1)
        XCTAssertFalse(controls.isActive)
        XCTAssertEqual(view.selectedRange, .init(location: view.text.utf16.count, length: 0))
        XCTAssertTrue(view.isFirstResponder)
    }

    func testSnippetIMEAndExternalReplacementKeepNavigationSafe() async throws {
        let box = EditorBox("join"); box.selection = .init(location: 4, length: 0)
        let controls = MobileSQLSnippetContext()
        let (view, coordinator, window, previous) = try mount(box, snippets: SQLSnippetStore.shared.completionSources, snippetContext: controls)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.kind == .snippet } }
        XCTAssertTrue(coordinator.accept(try XCTUnwrap(coordinator.items.firstIndex { $0.kind == .snippet })))
        XCTAssertTrue(controls.isActive)
        XCTAssertEqual(coordinator.source.text, view.text)
        let beforeIME = "text=\(view.text ?? ""), source=\(coordinator.source.text), selection=\(view.selectedRange), ranges=\(coordinator.snippetSession.placeholderRanges)"
        view.setMarkedText("中文", selectedRange: .init(location: 2, length: 0)); coordinator.textViewDidChange(view)
        XCTAssertTrue(controls.isComposing)
        XCTAssertTrue(controls.isActive, "Before: \(beforeIME); After: \(view.text ?? ""), source=\(coordinator.source.text), selection=\(view.selectedRange)")
        XCTAssertEqual(coordinator.snippetSession.currentIndex, 0)
        let range = view.selectedRange
        controls.move(1); XCTAssertEqual(view.selectedRange, range)
        XCTAssertNotNil(view.markedTextRange)
        view.unmarkText(); coordinator.textViewDidChange(view)
        try await wait { view.markedTextRange == nil && !controls.isComposing }
        XCTAssertTrue(controls.isActive)
        XCTAssertEqual(coordinator.snippetSession.currentIndex, 0,
                       "Ranges: \(coordinator.snippetSession.placeholderRanges), selection: \(view.selectedRange), text: \(view.text ?? "")")
        controls.move(1)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "left_column")
        box.text = "SELECT 42;"; box.selection = .init(location: 10, length: 0)
        coordinator.update(view, mode: .light)
        XCTAssertFalse(controls.isActive)
        XCTAssertTrue(view.snippetHints.isEmpty)
        XCTAssertFalse(coordinator.navigateSnippet(1))
    }

    func testChangingEnabledSnippetsRetiresPendingCandidatesImmediately() async throws {
        let box = EditorBox("sel"); box.selection = .init(location: 3, length: 0)
        let (view, coordinator, window, previous) = try mount(box, snippets: SQLSnippetStore.shared.completionSources)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        try await wait { coordinator.items.contains { $0.kind == .snippet } }
        coordinator.parent.snippets = []; coordinator.update(view, mode: .light)
        XCTAssertTrue(coordinator.items.isEmpty)
        try await wait { coordinator.items.contains { $0.label == "SELECT" } }
        XCTAssertFalse(coordinator.items.contains { $0.kind == .snippet })
    }

    private func mount(_ box: EditorBox, schema: MobileSQLSchemaCatalog = MobileSQLSchemaCatalog(), defaultDatabase: String = "",
                       snippets: [SQLSnippetCompletionSource] = [], snippetContext: MobileSQLSnippetContext? = nil) throws -> (MobileSQLTextView, MobileSQLEditor.Coordinator, UIWindow, UIWindow?) {
        let editor = MobileSQLEditor(text: .init(get: { box.text }, set: { box.text = $0 }),
            selection: .init(get: { box.selection }, set: { box.selection = $0 }),
            isFocused: .init(get: { box.focused }, set: { box.focused = $0 }), schema: schema, defaultDatabase: defaultDatabase,
            snippets: snippets, snippetContext: snippetContext) {}
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

private struct CompletionCatalog: MobileSQLMetadataProviding {
    func editorCatalog(configuration: MobileSQLConfiguration) async throws -> [WorkspaceSchemaDatabase] {
        [.init(name: "proof", objects: [.init(name: "sample", kind: .table, columns: [])])]
    }
    func editorColumns(configuration: MobileSQLConfiguration, references: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        references.map { .init(reference: $0, columns: [.init(name: "id", type: "int", ordinalPosition: 1)]) }
    }
    func editorContext(configuration: MobileSQLConfiguration) async throws -> SQLHighlightContext { .init(databaseType: .mysql) }
}

@MainActor private final class EditorBox {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var focused = false
    init(_ text: String) { self.text = text }
}
