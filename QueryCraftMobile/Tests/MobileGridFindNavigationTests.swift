import XCTest
import UIKit
import SwiftUI
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileGridFindNavigationTests: XCTestCase {
    func testQueryFindCollapsesEditorAndRestoresDraftWithoutReplacingGridState() async throws {
        let model = MobileQueryModel(executor: FindResultExecutor())
        model.sql = "SELECT id, name FROM sample;\n-- keep this draft"
        await model.execute()?.value
        let draft = model.sql
        let host = UIHostingController(rootView: NavigationStack { MobileWorkspaceView(model: model, widthKey: UUID().uuidString) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        // A disconnected legacy UIWindow can lay out UIKit but does not drive
        // SwiftUI's observable update cycle. Exercise a real simulator scene.
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previousKey?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(descendant(UITextView.self, in: host.view))
        let grid = try XCTUnwrap(descendant(UICollectionView.self, in: host.view))
        let coordinator = try XCTUnwrap(grid.dataSource as? MobileDataGrid.Coordinator)
        XCTAssertGreaterThan(grid.bounds.height, 54, "The result grid must retain space below the SQL editor")
        let search = try XCTUnwrap(coordinator.parent.searchController)
        let originalTop = grid.convert(grid.bounds, to: host.view).minY
        XCTAssertTrue(search.canSearch)
        search.present(); search.query = "second"
        XCTAssertTrue(search.isPresented)
        let deadline = ContinuousClock.now + .seconds(3)
        while grid.convert(grid.bounds, to: host.view).minY >= originalTop - 80, ContinuousClock.now < deadline {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        // SwiftUI retains an offscreen TextEditor platform view for reuse. Assert
        // reclaimed content space, not whether its cached UIKit object was deleted.
        XCTAssertLessThan(grid.convert(grid.bounds, to: host.view).minY, originalTop - 80, "Result find must reclaim editor space")
        XCTAssertEqual(model.sql, draft)
        XCTAssertEqual(grid.numberOfSections, 3)
        search.dismiss()
        let restoreDeadline = ContinuousClock.now + .seconds(3)
        while grid.convert(grid.bounds, to: host.view).minY < originalTop - 1, ContinuousClock.now < restoreDeadline {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(grid.convert(grid.bounds, to: host.view).minY, originalTop, accuracy: 1)
        XCTAssertNotNil(descendant(UITextView.self, in: host.view))
        XCTAssertEqual(model.sql, draft)
        XCTAssertTrue(coordinator.parent.searchController === search)
    }

    func testSharedControllerSelectsFarCellAndKeyboardResizeKeepsItVisibleWithoutFiltering() async throws {
        let data = MobileGridData(columns: (0..<20).map { "column_\($0)" },
                                  rows: (0..<100).map { row in (0..<20).map { "\(row):\($0)" } })
        let search = WorkspaceGridSearchController(), state = MobileGridViewport()
        let grid = MobileDataGrid(data: data, revision: "page", widthKey: UUID().uuidString,
                                  viewport: state, searchController: search, revealsMatchOnResize: true) { _, _ in XCTFail("Find must not open the inspector") }
        let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        grid.apply(to: view, coordinator: coordinator)
        search.update(source: MobileGridSearchSource(revision: UUID(), data: data))
        search.present(); search.query = "90:17"; search.searchOperator = .equals
        let deadline = ContinuousClock.now + .seconds(3)
        while search.isSearching, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(search.isSearching)
        XCTAssertEqual(view.numberOfSections, 101)
        let path = IndexPath(item: 17, section: 91)
        XCTAssertEqual(view.indexPathsForSelectedItems, [path])
        XCTAssertGreaterThan(view.contentOffset.x, 0)
        XCTAssertGreaterThan(view.contentOffset.y, 0)
        assertVisible(path, in: view)
        view.frame.size.height = 240
        view.setNeedsLayout(); view.layoutIfNeeded()
        assertVisible(path, in: view)
        XCTAssertEqual(state.selection, path)
        XCTAssertEqual(state.offset, view.contentOffset)
        // Once input ends, returning from fullscreen or resizing must preserve
        // the user's viewport even if the old found cell remains selected.
        coordinator.parent.revealsMatchOnResize = false
        view.setContentOffset(.zero, animated: false)
        view.frame.size.height = 300
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset, .zero)
    }

    func testFindOverridesGestureLockButCannotMoveInactiveFullscreenBackground() {
        let data = MobileGridData(columns: ["a", "b"], rows: (0..<100).map { ["\($0)", "value"] })
        let state = MobileGridViewport()
        let grid = MobileDataGrid(data: data, revision: "page", widthKey: UUID().uuidString, viewport: state) { _, _ in }
        let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 180, height: 260)
        grid.apply(to: view, coordinator: coordinator)
        coordinator.axisLock.begin(at: .zero, translation: CGPoint(x: 10, y: 1))
        coordinator.reveal(.init(rowIndex: 80, dataColumnIndex: 1), in: view)
        XCTAssertFalse(coordinator.axisLock.isTracking)
        XCTAssertEqual(view.indexPathsForSelectedItems, [IndexPath(item: 1, section: 81)])
        let offset = view.contentOffset
        state.activeOwner = UUID()
        coordinator.reveal(.init(rowIndex: 0, dataColumnIndex: 0), in: view)
        XCTAssertEqual(view.contentOffset, offset)
        XCTAssertEqual(view.indexPathsForSelectedItems, [IndexPath(item: 1, section: 81)])
    }

    private func assertVisible(_ path: IndexPath, in view: UICollectionView, file: StaticString = #filePath, line: UInt = #line) {
        guard let frame = view.collectionViewLayout.layoutAttributesForItem(at: path)?.frame else {
            XCTFail("Missing matching cell layout", file: file, line: line); return
        }
        let header = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame.height
        XCTAssertGreaterThanOrEqual(frame.minY, view.contentOffset.y + header, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, view.contentOffset.y + view.bounds.height, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, view.contentOffset.x, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, view.contentOffset.x + view.bounds.width, file: file, line: line)
    }

    private func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

private struct FindResultExecutor: MobileQueryExecuting {
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        .init(columns: ["id", "name"], rows: [["1", "first"], ["2", "second"]])
    }
}
