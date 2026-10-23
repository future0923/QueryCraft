import XCTest
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileTimestampGridTests: XCTestCase {
    private func data() -> MobileGridData {
        .init(preview: .init(result: .init(columns: ["created_at", "id"], columnTypes: ["bigint", "bigint"],
            rows: (0..<100).map { _ in ["1700000000", "318987599031067570"] })))
    }

    func testNativeHeaderFormatActionsRefreshVisibleTextAndKeepRawCells() throws {
        let data = data(), viewport = MobileGridViewport()
        let grid = MobileDataGrid(data: data, revision: "a", widthKey: UUID().uuidString, viewport: viewport) { _, _ in }
        let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        grid.apply(to: view, coordinator: coordinator)
        let cellPath = IndexPath(item: 0, section: 1), headerPath = IndexPath(item: 0, section: 0)
        let cell = try XCTUnwrap(view.cellForItem(at: cellPath))
        let formatted = WorkspaceTimestampDisplayFormatter.shared.timestamp("1700000000", column: data.metadata[0])
        XCTAssertEqual(cell.accessibilityLabel, "created_at，\(formatted ?? "")")
        let header = try XCTUnwrap(view.cellForItem(at: headerPath))
        XCTAssertEqual(header.accessibilityCustomActions?.count, 4)
        XCTAssertNotNil(coordinator.collectionView(view, contextMenuConfigurationForItemAt: headerPath, point: .zero))
        XCTAssertNil(coordinator.collectionView(view, contextMenuConfigurationForItemAt: cellPath, point: .zero))
        let otherWidth = coordinator.widths[1]
        view.selectItem(at: cellPath, animated: false, scrollPosition: [])
        let action = try XCTUnwrap(header.accessibilityCustomActions?.first { $0.name == WorkspaceTimestampDisplayMode.raw.title })
        XCTAssertEqual(action.actionHandler?(action), true)
        view.layoutIfNeeded()
        XCTAssertEqual(coordinator.timestampDisplay.mode(column: 0), .raw)
        let rawCell = try XCTUnwrap(view.cellForItem(at: cellPath))
        XCTAssertEqual(rawCell.accessibilityLabel, "created_at，1700000000")
        XCTAssertEqual(coordinator.widths[1], otherWidth)
        XCTAssertEqual(view.indexPathsForSelectedItems, [cellPath])
        XCTAssertEqual(data.cell(row: 0, column: 0), .text("1700000000"))
        // Stale header actions must not change a different object with the same names.
        let replacement = MobileDataGrid(data: data, revision: "b", widthKey: "other", viewport: viewport) { _, _ in }
        replacement.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(action.actionHandler?(action), false)
        XCTAssertEqual(coordinator.timestampDisplay.mode(column: 0), .automatic)
        // A new SQL result keeps its width key but has a new display scope.
        let query = MobileDataGrid(data: data, revision: "q1", widthKey: "query", viewport: viewport, timestampScope: "q1") { _, _ in }
        query.apply(to: view, coordinator: coordinator)
        let queryHeader = try XCTUnwrap(view.cellForItem(at: headerPath))
        let staleAction = try XCTUnwrap(queryHeader.accessibilityCustomActions?.first { $0.name == WorkspaceTimestampDisplayMode.raw.title })
        coordinator.setTimestampMode(.raw, column: 0, in: view)
        let nextResult = MobileDataGrid(data: data, revision: "q2", widthKey: "query", viewport: viewport, timestampScope: "q2") { _, _ in }
        nextResult.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(coordinator.timestampDisplay.mode(column: 0), .automatic)
        XCTAssertEqual(staleAction.actionHandler?(staleAction), false)
    }

    func testFullscreenFormatSharingRejectsBackgroundAndRestoresViewport() {
        let data = data(), viewport = MobileGridViewport(), key = UUID().uuidString
        let normal = MobileDataGrid(data: data, revision: "a", widthKey: key, viewport: viewport) { _, _ in }
        let coordinator = normal.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        normal.apply(to: view, coordinator: coordinator)
        coordinator.setTimestampMode(.raw, column: 0, in: view)
        view.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        coordinator.saveViewport(view)
        let owner = UUID(); viewport.activeOwner = owner
        let full = MobileDataGrid(data: data, revision: "a", widthKey: key, viewport: viewport, viewportOwner: owner) { _, _ in }
        let fullCoordinator = full.makeCoordinator(), fullView = MobileDataGrid.makeCollectionView(coordinator: fullCoordinator)
        fullView.frame = view.frame
        full.apply(to: fullView, coordinator: fullCoordinator)
        XCTAssertEqual(fullCoordinator.timestampDisplay.mode(column: 0), .raw)
        XCTAssertEqual(fullView.contentOffset.y, 500)
        fullCoordinator.setTimestampMode(.milliseconds, column: 0, in: fullView)
        coordinator.setTimestampMode(.seconds, column: 0, in: view)
        XCTAssertEqual(fullCoordinator.timestampDisplay.mode(column: 0), .milliseconds)
        // Hidden background updates must not reset the active fullscreen format.
        let background = MobileDataGrid(data: .init(columns: [], rows: []), revision: "empty", widthKey: key, viewport: viewport, tracksViewport: false) { _, _ in }
        background.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(fullCoordinator.timestampDisplay.mode(column: 0), .milliseconds)
        viewport.activeOwner = nil
        let restored = MobileDataGrid(data: data, revision: "a", widthKey: key, viewport: viewport, restorationID: UUID()) { _, _ in }
        restored.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(coordinator.timestampDisplay.mode(column: 0), .milliseconds)
        XCTAssertEqual(view.contentOffset.y, 500)
        let refresh = MobileDataGrid(data: data, revision: "refresh", widthKey: key, viewport: viewport, restorationID: restored.restorationID) { _, _ in }
        refresh.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(coordinator.timestampDisplay.mode(column: 0), .milliseconds)
        XCTAssertEqual(view.contentOffset.y, 500)
    }
}
