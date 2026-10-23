import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileDataEditingPresentationTests: XCTestCase {
    func testPendingColorsAccessibilityAndRefreshPreserveGridGeometry() throws {
        var data = MobileGridData(columns: ["id","name"], rows: (0..<100).map { [String($0),"pending"] })
        data.pendingCells = [.init(row: 0, column: 1)]; data.deletedRows = [1]
        let viewport = MobileGridViewport()
        let grid = MobileDataGrid(data: data, revision: "staged", widthKey: UUID().uuidString, viewport: viewport) { _, _ in }
        let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        grid.apply(to: view, coordinator: coordinator)
        XCTAssertTrue(try XCTUnwrap(view.cellForItem(at: .init(item: 1, section: 1))).accessibilityLabel?.contains("待提交") == true)
        XCTAssertTrue(try XCTUnwrap(view.cellForItem(at: .init(item: 0, section: 2))).accessibilityLabel?.contains("待删除") == true)
        let widths = coordinator.widths
        view.setContentOffset(.init(x: 0, y: 500), animated: false)
        let refreshed = MobileDataGrid(data: data, revision: "refreshed", widthKey: grid.widthKey, viewport: viewport) { _, _ in }
        refreshed.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(coordinator.widths, widths); XCTAssertEqual(view.contentOffset.y, 500)
    }

    func testNativeCellEditorReturnDismissesKeyboardWithoutChangingDraftOrStaging() async throws {
        let columns = [MobileTableColumn(name: "id", type: "int", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: ""),
            .init(name: "name", type: "varchar(80)", isNullable: true, key: "", defaultValue: nil, extra: "", comment: "")]
        let page = MobileTableSnapshot(object: .init(database: "db", name: "table", kind: .table, comment: ""),
            preview: .init(result: .init(columns: ["id","name"], rows: [["1","before"]])), columns: columns,
            offset: 0, pageSize: 100, hasNextPage: false, hasStableOrder: true)
        let changes = MobileTableChanges(object: page.object, metadata: columns,
            configuration: .init(host: "127.0.0.1", port: 1, username: "unused", password: nil, database: "db", tlsMode: .disabled),
            safetyLock: WorkspaceSafetyLock())
        let request = try changes.request(page: page, row: 0, column: 1)
        let host = UIHostingController(rootView: MobileCellEditView(request: request, changes: changes, deleteRow: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        let inputs = descendants(host.view)
        if let input = inputs.compactMap({ $0 as? UITextView }).first(where: { $0.text == "before" }) {
            XCTAssertEqual(input.returnKeyType, .done)
            XCTAssertTrue(input.becomeFirstResponder()); try await Task.sleep(for: .milliseconds(50))
            _ = input.delegate?.textView?(input, shouldChangeTextIn: NSRange(location: input.text.utf16.count, length: 0), replacementText: "\n")
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(input.isFirstResponder); XCTAssertEqual(input.text, "before")
        } else {
            let input = try XCTUnwrap(inputs.compactMap { $0 as? UITextField }.first { $0.text == "before" })
            XCTAssertEqual(input.returnKeyType, .done)
            XCTAssertTrue(input.becomeFirstResponder()); try await Task.sleep(for: .milliseconds(50))
            _ = input.delegate?.textFieldShouldReturn?(input)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(input.isFirstResponder); XCTAssertEqual(input.text, "before")
        }
        XCTAssertFalse(changes.hasChanges); XCTAssertTrue(changes.safetyLock.isEnabled)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
