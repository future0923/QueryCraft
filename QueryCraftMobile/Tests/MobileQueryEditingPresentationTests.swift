import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileQueryEditingPresentationTests: XCTestCase {
    func testQueryGridTapOpensSharedNativeEditorAndDoneKeepsResultDraftAndGeometry() async throws {
        let model = MobileQueryModel(executor: QueryEditingExecutor(), metadataService: QueryEditingMetadata())
        model.database = "db"; model.sql = "SELECT id,name FROM t"
        await model.execute()?.value
        let changes = try XCTUnwrap(model.editing)
        let host = UIHostingController(rootView: NavigationStack { MobileWorkspaceView(model: model, widthKey: UUID().uuidString) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(200))
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
        let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
        let widths = coordinator.widths, frame = grid.frame
        coordinator.collectionView(grid, didSelectItemAt: .init(item: 1, section: 1))
        try await Task.sleep(for: .milliseconds(400))
        let presented = try XCTUnwrap(host.presentedViewController)
        let input = try XCTUnwrap(descendants(presented.view).compactMap { $0 as? UITextView }.first { $0.text == "before" })
        XCTAssertEqual(input.returnKeyType, .done)
        XCTAssertTrue(input.becomeFirstResponder())
        _ = input.delegate?.textView?(input, shouldChangeTextIn: .init(location: input.text.utf16.count, length: 0), replacementText: "\n")
        XCTAssertFalse(input.isFirstResponder); XCTAssertEqual(input.text, "before")
        XCTAssertEqual(model.sql, "SELECT id,name FROM t"); XCTAssertFalse(changes.hasChanges)
        host.dismiss(animated: false); try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        XCTAssertEqual(coordinator.widths, widths); XCTAssertEqual(grid.frame, frame)
        let request = try changes.request(page: XCTUnwrap(model.editingPage), row: 0, column: 1)
        try changes.stage(request, text: "pending", mode: .value)
        try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        XCTAssertTrue(try XCTUnwrap(grid.cellForItem(at: .init(item: 1, section: 1))).accessibilityLabel?.contains("待提交") == true)
        XCTAssertTrue(changes.safetyLock.isEnabled)
        changes.discard()
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
