import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileQueryBatchPresentationTests: XCTestCase {
    func testActualEditorCommandShiftReturnRunsWholeDocumentWithoutChangingSelection() async throws {
        let model = MobileQueryModel(executor: BatchPresentationExecutor())
        model.sql = "SELECT 1; SELECT '雪;👋';"
        let selection = NSRange(location: 4, length: 0)
        model.executionInput.selection = selection
        let editor = MobileSQLEditor(text: .init(get: { model.sql }, set: { model.sql = $0 }),
            selection: .init(get: { model.executionInput.selection }, set: { model.executionInput.selection = $0 }),
            isFocused: .constant(false), schema: MobileSQLSchemaCatalog(), defaultDatabase: "",
            executionInput: model.executionInput, executeAll: { model.executeAll() }) { model.execute() }
        let coordinator = editor.makeCoordinator(), view = MobileSQLEditor.makeTextView(coordinator: coordinator)
        let host = UIViewController(), (window, previous) = try mount(host)
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        host.view.addSubview(view); view.frame = .init(x: 12, y: 60, width: 330, height: 150)
        coordinator.update(view, mode: .light)
        let command = try XCTUnwrap(view.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == [.command, .shift] })
        _ = view.perform(command.action)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.statementResults.count, 2)
        XCTAssertEqual(view.text, model.sql); XCTAssertEqual(view.selectedRange, selection)
    }

    func testActualWorkspaceRendersDifferentResultsWithStableEditorAndGridFrame() async throws {
        let model = MobileQueryModel(executor: BatchPresentationExecutor())
        model.sql = "SELECT 1; SELECT '雪;👋';"
        await model.executeAll()?.value
        let host = UIHostingController(rootView: NavigationStack {
            MobileWorkspaceView(model: model, widthKey: "batch-presentation").environment(\.scenePhase, .active)
        })
        let (window, previous) = try mount(host)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(descendants(host.view).compactMap { $0 as? MobileSQLTextView }.first)
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        let frame = grid.convert(grid.bounds, to: host.view)
        for index in [1, 0] {
            XCTAssertTrue(model.selectResult(model.statementResults[index].id))
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
            XCTAssertTrue(descendants(host.view).contains { $0 === editor }, "Result switching must retain the editor and native selection")
            let current = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
            XCTAssertEqual(current.convert(current.bounds, to: host.view), frame)
            XCTAssertEqual(model.result?.rows.first?.first, model.statementResults[index].statement?.sql)
        }
        for (style, name) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = "sql-batch-results-" + name
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func mount(_ host: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        return (window, previous)
    }
}

private struct BatchPresentationExecutor: MobileQueryExecuting {
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        .init(columns: ["实际执行 SQL"], rows: [[sql]])
    }
}
