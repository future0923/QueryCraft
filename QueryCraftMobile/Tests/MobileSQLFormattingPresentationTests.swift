import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileSQLFormattingPresentationTests: XCTestCase {
    func testCurrentStatementPublishesNativeTextAndUndoesInOneStep() async throws {
        let original = "select a,b from users;\nselect 'untouched;字👋';"
        let model = MobileQueryModel(), context = MobileSQLFormattingContext()
        model.sql = original
        let (view, coordinator, window, previous) = try mount(model, context)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder(); view.selectedRange = .init(location: 8, length: 0)
        view.undoManager?.removeAllActions()
        await context.format(.selectionOrCurrentStatement)?.value
        XCTAssertNil(context.errorMessage)
        XCTAssertTrue(view.text.hasPrefix("SELECT\n")); XCTAssertTrue(view.text.hasSuffix("\nselect 'untouched;字👋';"))
        XCTAssertEqual(model.sql, view.text); XCTAssertEqual(model.executionInput.selection, view.selectedRange)
        XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undoManager?.undo()
        XCTAssertEqual(view.text, original)
        XCTAssertEqual(model.sql, original)
    }

    func testUTF16SelectionAndDocumentUseSharedFormatter() async throws {
        let original = "select '字👋;';\nselect a,b from users;\nselect 3;"
        let model = MobileQueryModel(), context = MobileSQLFormattingContext()
        model.sql = original
        let (view, coordinator, window, previous) = try mount(model, context)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        let selection = (original as NSString).range(of: "select a,b from users;")
        view.selectedRange = selection
        await context.format(.selectionOrCurrentStatement)?.value
        XCTAssertNil(context.errorMessage)
        XCTAssertTrue(view.text.hasPrefix("select '字👋;';\nSELECT\n")); XCTAssertTrue(view.text.hasSuffix("\nselect 3;"))
        await context.format(.document)?.value
        XCTAssertNil(context.errorMessage); XCTAssertTrue(view.text.hasPrefix("SELECT"))
        let formatted = view.text
        await context.format(.document)?.value
        XCTAssertNil(context.errorMessage); XCTAssertEqual(view.text, formatted)
    }

    func testCompositionIsPreservedAndEmptyDocumentReportsError() async throws {
        let model = MobileQueryModel(), context = MobileSQLFormattingContext()
        model.sql = "select 'name';"
        let (view, coordinator, window, previous) = try mount(model, context)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        XCTAssertTrue(view.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(250))
        view.selectedRange = (view.text as NSString).range(of: "name")
        view.setMarkedText("中文", selectedRange: .init(location: 2, length: 0))
        coordinator.textViewDidChange(view)
        let text = view.text
        XCTAssertNotNil(view.markedTextRange, "Establish native composition before requesting formatting")
        XCTAssertNil(context.format(.document), "Reject at the synchronous toolbar boundary before input-method IPC can finish composition")
        XCTAssertEqual(context.errorMessage, SQLFormattingError.textCompositionActive.localizedDescription)
        XCTAssertEqual(view.text, text); XCTAssertNotNil(view.markedTextRange)
        view.unmarkText(); view.text = "   "; coordinator.textViewDidChange(view)
        await context.format(.document)?.value
        XCTAssertEqual(context.errorMessage, SQLFormattingError.emptyDocument.localizedDescription)
        XCTAssertEqual(view.text, "   ")
    }

    func testFormattingRejectsInputChangedBeforeItsTaskStarts() async throws {
        for changeText in [false, true] {
            let model = MobileQueryModel(), context = MobileSQLFormattingContext()
            model.sql = "select a,b from users;"
            let (view, coordinator, window, previous) = try mount(model, context)
            defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
            let task = context.format(.document)
            XCTAssertNotNil(task)
            if changeText {
                view.text += " "; coordinator.textViewDidChange(view)
            } else {
                view.selectedRange = .init(location: 2, length: 0); coordinator.textViewDidChangeSelection(view)
            }
            let expected = view.text, selection = view.selectedRange
            await task?.value
            XCTAssertEqual(context.errorMessage, SQLFormattingError.sourceChanged.localizedDescription)
            XCTAssertEqual(view.text, expected); XCTAssertEqual(view.selectedRange, selection)
        }
    }

    func testLateFormattingRejectsCaretAndTextChangesEvenWhenRestored() async throws {
        for changeText in [false, true] {
            let model = MobileQueryModel(), context = MobileSQLFormattingContext(), gate = FormattingGate()
            model.sql = "select a,b from users;"
            let (view, coordinator, window, previous) = try mount(model, context)
            defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
            coordinator.formatter = gate
            let original = view.text!, selection = view.selectedRange
            let task = context.format(.document)
            await gate.waitUntilStarted()
            if changeText {
                view.text += " "; coordinator.textViewDidChange(view)
                view.text = original; coordinator.textViewDidChange(view)
            } else {
                view.selectedRange = .init(location: 2, length: 0); coordinator.textViewDidChangeSelection(view)
                view.selectedRange = selection; coordinator.textViewDidChangeSelection(view)
            }
            await gate.release(); await task?.value
            XCTAssertEqual(view.text, original)
            XCTAssertEqual(context.errorMessage, SQLFormattingError.sourceChanged.localizedDescription)
        }
    }

    func testBackgroundCancellationAndDetachNeverApplyLateEdit() async throws {
        for detach in [false, true] {
            let model = MobileQueryModel(), context = MobileSQLFormattingContext(), gate = FormattingGate()
            model.sql = "select a,b from users;"
            let (view, coordinator, window, previous) = try mount(model, context)
            defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
            coordinator.formatter = gate
            let original = view.text
            let task = context.format(.document)
            await gate.waitUntilStarted()
            if detach { coordinator.stop() } else { context.cancel() }
            await gate.release(); await task?.value
            XCTAssertEqual(view.text, original); XCTAssertNil(context.errorMessage); XCTAssertFalse(context.isFormatting)
        }
    }

    func testCommandIMatchesMacFormattingShortcut() async throws {
        let model = MobileQueryModel(), context = MobileSQLFormattingContext()
        model.sql = "select a,b from users;"
        let (view, coordinator, window, previous) = try mount(model, context)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        let command = try XCTUnwrap(view.keyCommands?.first { $0.input == "i" && $0.modifierFlags == .command })
        _ = view.perform(command.action)
        let deadline = ContinuousClock.now + .seconds(5)
        while context.isFormatting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(context.errorMessage); XCTAssertTrue(view.text.hasPrefix("SELECT\n"))
    }

    func testUnchangedHighlightSchedulingDoesNotInvalidateFormatting() async throws {
        let model = MobileQueryModel(), context = MobileSQLFormattingContext(), gate = FormattingGate()
        model.sql = "select a,b from users;"
        let (view, coordinator, window, previous) = try mount(model, context)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        coordinator.formatter = gate
        let task = context.format(.document)
        await gate.waitUntilStarted()
        coordinator.schedule(view) // Metadata/theme/viewport work is not a document edit.
        await gate.release(); await task?.value
        XCTAssertNil(context.errorMessage); XCTAssertTrue(view.text.hasPrefix("SELECT\n"))
    }

    func testActualWorkspaceFormattingPublishesWithoutChangingResultsAndRendersBothAppearances() async throws {
        let model = MobileQueryModel()
        model.sql = "select id,name from users where id>1 order by id;"
        let status = model.status, resultID = model.resultID
        let host = UIHostingController(rootView: NavigationStack {
            MobileWorkspaceView(model: model, widthKey: "format-render").environment(\.scenePhase, .active)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !descendants(host.view).contains(where: { $0 is MobileSQLTextView }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(descendants(host.view).compactMap { $0 as? MobileSQLTextView }.first)
        let action = try XCTUnwrap(editor.formatSQL)
        let changed = try await action(.document)
        XCTAssertTrue(changed)
        XCTAssertEqual(model.sql, editor.text); XCTAssertEqual(model.status, status); XCTAssertEqual(model.resultID, resultID)
        for (style, name) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = "sql-formatting-workspace-" + name
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func mount(_ model: MobileQueryModel, _ formatting: MobileSQLFormattingContext) throws -> (MobileSQLTextView, MobileSQLEditor.Coordinator, UIWindow, UIWindow?) {
        let editor = MobileSQLEditor(text: .init(get: { model.sql }, set: { model.sql = $0 }),
            selection: .init(get: { model.executionInput.selection }, set: { model.executionInput.selection = $0 }),
            isFocused: .constant(false), schema: MobileSQLSchemaCatalog(), defaultDatabase: "", formattingContext: formatting) { }
        let coordinator = editor.makeCoordinator(), view = MobileSQLEditor.makeTextView(coordinator: coordinator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; host.view.addSubview(view); window.makeKeyAndVisible()
        view.frame = CGRect(x: 10, y: 80, width: 350, height: 160)
        coordinator.update(view, mode: .light)
        return (view, coordinator, window, previous)
    }
}

private actor FormattingGate: MobileSQLFormatting {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
    func edit(for request: SQLFormattingRequest, source: SQLSourceSnapshot, selection: NSRange) async throws -> SQLFormattingEdit? {
        await withCheckedContinuation {
            continuation = $0; started = true
            waiters.forEach { $0.resume() }; waiters = []
        }
        return try await MobileSQLFormatter().edit(for: request, source: source, selection: selection)
    }
}
