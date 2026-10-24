import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileSQLExecutionPresentationTests: XCTestCase {
    func testNativeCommandReturnUsesActualSelectionAndPreservesWholeEditor() async throws {
        let executor = NativeTargetExecutor(), model = MobileQueryModel(executor: executor)
        model.sql = "-- 中文 👋\nSELECT 1;\nSELECT 'semi;colon' AS n;\nSELECT 3;"
        let (view, coordinator, window, previous) = try mount(model)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        let selected = (model.sql as NSString).range(of: "SELECT 'semi;colon' AS n;")
        view.selectedRange = selected
        // Deliberately stale model binding: the real view is authoritative at run time.
        model.executionInput.selection = .init(location: 0, length: 0)
        let command = try XCTUnwrap(view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .command })
        _ = view.perform(command.action)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.result)
        let statements = await executor.statements
        XCTAssertEqual(statements, ["SELECT 'semi;colon' AS n;"])
        XCTAssertEqual(view.text, model.sql); XCTAssertTrue(model.sql.contains("SELECT 3;"))
        XCTAssertEqual(view.selectedRange, selected); XCTAssertEqual(model.executionInput.selection, selected)
        model.executionInput.detach(view)
        await model.execute()?.value
        let replay = await executor.statements
        XCTAssertEqual(replay.count, 2, "Selection survives editor recreation/navigation")
    }

    func testMarkedTextBlocksToolbarAndCommandReturnDoesNotRunQuery() async throws {
        let executor = NativeTargetExecutor(), model = MobileQueryModel(executor: executor)
        model.sql = "SELECT 'name';"
        let (view, coordinator, window, previous) = try mount(model)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        view.becomeFirstResponder()
        view.selectedRange = (view.text as NSString).range(of: "name")
        view.setMarkedText("中文", selectedRange: .init(location: 2, length: 0))
        coordinator.textViewDidChange(view)
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertNil(model.execute(), "Toolbar run must not execute uncommitted IME composition")
        XCTAssertEqual(model.errorMessage, SQLExecutionTargetError.textCompositionActive.localizedDescription)
        let command = try XCTUnwrap(view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .command })
        _ = view.perform(command.action)
        try await Task.sleep(for: .milliseconds(80))
        let statements = await executor.statements
        XCTAssertTrue(statements.isEmpty)
        XCTAssertTrue(view.text.contains("中文")); XCTAssertNil(view.markedTextRange)
    }

    private func mount(_ model: MobileQueryModel) throws -> (MobileSQLTextView, MobileSQLEditor.Coordinator, UIWindow, UIWindow?) {
        let editor = MobileSQLEditor(text: .init(get: { model.sql }, set: { model.sql = $0 }),
            selection: .init(get: { model.executionInput.selection }, set: { model.executionInput.selection = $0 }),
            isFocused: .constant(false), schema: MobileSQLSchemaCatalog(), defaultDatabase: "", executionInput: model.executionInput) { model.execute() }
        let coordinator = editor.makeCoordinator(), view = MobileSQLEditor.makeTextView(coordinator: coordinator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; host.view.addSubview(view); window.makeKeyAndVisible()
        view.frame = CGRect(x: 10, y: 80, width: 350, height: 160)
        coordinator.update(view, mode: .light)
        return (view, coordinator, window, previous)
    }
}
private actor NativeTargetExecutor: MobileQueryExecuting {
    private(set) var statements: [String] = []
    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        statements.append(sql); return .init(columns: ["n"], rows: [["1"]])
    }
}
