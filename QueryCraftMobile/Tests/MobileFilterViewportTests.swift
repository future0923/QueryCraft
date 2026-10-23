import XCTest
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileFilterViewportTests: XCTestCase {
    func testSamePageRefreshPreservesViewportButNewFilterResetsRowAndRetainsColumns() {
        let data = MobileGridData(columns: ["created_at", "id"], rows: (0..<100).map { ["\($0)", "\($0)"] })
        let state = MobileGridViewport(), key = UUID().uuidString
        let first = context(offset: 100, filter: .empty)
        let grid = MobileDataGrid(data: data, revision: "first", widthKey: key, viewport: state, pageContext: first) { _, _ in }
        let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 250, height: 240)
        grid.apply(to: view, coordinator: coordinator)
        coordinator.widths = [220, 200]
        (view.collectionViewLayout as? MobileGridLayout)?.widths = coordinator.widths
        view.layoutIfNeeded()
        view.contentOffset = CGPoint(x: 90, y: 500)
        let selected = IndexPath(item: 1, section: 20)
        view.selectItem(at: selected, animated: false, scrollPosition: [])
        coordinator.timestampDisplay.set(.raw, column: 0)
        coordinator.saveViewport(view)
        let refresh = MobileDataGrid(data: data, revision: "refresh", widthKey: key, viewport: state, pageContext: first) { _, _ in }
        refresh.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 90, y: 500))
        XCTAssertEqual(view.indexPathsForSelectedItems, [selected])
        let filter = WorkspaceDatabaseDataFilter(conditions: [.init(columnName: "id", columnKind: .number, operation: .greaterThan, value: "50")])
        let filtered = context(offset: 0, filter: filter)
        let replacement = MobileDataGrid(data: data, revision: "filtered", widthKey: key, viewport: state, pageContext: filtered) { _, _ in }
        replacement.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 90, y: 0))
        XCTAssertTrue(view.indexPathsForSelectedItems?.isEmpty != false)
        XCTAssertEqual(coordinator.widths, [220, 200])
        XCTAssertEqual(coordinator.timestampDisplay.mode(column: 0), .raw)
        view.contentOffset.y = 700; coordinator.saveViewport(view)
        let owner = UUID(); state.activeOwner = owner
        let full = MobileDataGrid(data: data, revision: "filtered", widthKey: key, viewport: state, viewportOwner: owner, pageContext: filtered) { _, _ in }
        let fullCoordinator = full.makeCoordinator(), fullView = MobileDataGrid.makeCollectionView(coordinator: fullCoordinator)
        fullView.frame = view.frame
        full.apply(to: fullView, coordinator: fullCoordinator)
        XCTAssertEqual(fullView.contentOffset, CGPoint(x: 90, y: 700))
        state.activeOwner = nil
        let nextPage = MobileDataGrid(data: data, revision: "next", widthKey: key, viewport: state, restorationID: UUID(), pageContext: context(offset: 100, filter: filter)) { _, _ in }
        nextPage.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 90, y: 0), "Another page must not restore the old fullscreen row")
        XCTAssertEqual(coordinator.widths, [220, 200])
    }

    private func context(offset: Int, filter: WorkspaceDatabaseDataFilter) -> MobileGridPageContext {
        .init(page: .init(object: .init(database: "db", name: "t", kind: .table, comment: ""),
            preview: .init(result: .init()), columns: [], offset: offset, pageSize: 100, hasNextPage: true, hasStableOrder: true, filter: filter))
    }
}
