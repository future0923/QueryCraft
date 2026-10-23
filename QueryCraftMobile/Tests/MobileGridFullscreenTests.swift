import XCTest
import UIKit
import SwiftUI
@testable import QueryCraftMobileProof

@MainActor final class MobileGridFullscreenTests: XCTestCase {
    private var data: MobileGridData {
        .init(columns: (0..<20).map { "column_\($0)" }, rows: (0..<100).map { row in (0..<20).map { "\(row):\($0)" } })
    }

    func testFullscreenRoundTripPreservesViewportWidthsAndSelectionAndRejectsBackgroundWrites() {
        let state = MobileGridViewport(), key = UUID().uuidString, initialID = UUID()
        let normal = MobileDataGrid(data: data, revision: "page", widthKey: key, viewport: state, restorationID: initialID) { _, _ in }
        let coordinator = normal.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 220, height: 400)
        normal.apply(to: view, coordinator: coordinator)
        coordinator.widths[0] = 240
        (view.collectionViewLayout as? MobileGridLayout)?.widths = coordinator.widths
        view.collectionViewLayout.invalidateLayout(); view.layoutIfNeeded()
        view.contentOffset = CGPoint(x: 80, y: 160)
        view.selectItem(at: IndexPath(item: 2, section: 8), animated: false, scrollPosition: [])
        coordinator.saveViewport(view)

        let owner = UUID(); state.activeOwner = owner
        let full = MobileDataGrid(data: data, revision: "page", widthKey: key, viewport: state, viewportOwner: owner) { _, _ in }
        let fullCoordinator = full.makeCoordinator(), fullView = MobileDataGrid.makeCollectionView(coordinator: fullCoordinator)
        fullView.frame = CGRect(x: 0, y: 0, width: 760, height: 360)
        full.apply(to: fullView, coordinator: fullCoordinator)
        XCTAssertEqual(fullView.contentOffset, CGPoint(x: 80, y: 160))
        XCTAssertEqual(fullCoordinator.widths[0], 240)
        XCTAssertEqual(fullView.indexPathsForSelectedItems, [IndexPath(item: 2, section: 8)])
        fullView.contentOffset = CGPoint(x: 300, y: 240)
        fullView.selectItem(at: IndexPath(item: 5, section: 12), animated: false, scrollPosition: [])
        fullCoordinator.saveViewport(fullView)
        view.contentOffset = .zero
        coordinator.saveViewport(view)
        XCTAssertEqual(state.offset, CGPoint(x: 300, y: 240))

        state.activeOwner = nil
        let resumed = MobileDataGrid(data: data, revision: "page", widthKey: key, viewport: state, restorationID: UUID()) { _, _ in }
        resumed.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 300, y: 240))
        XCTAssertEqual(coordinator.widths[0], 240)
        XCTAssertEqual(view.indexPathsForSelectedItems, [IndexPath(item: 5, section: 12)])
        let other = MobileDataGrid(data: data, revision: "other", widthKey: "other", viewport: state, restorationID: UUID()) { _, _ in }
        other.apply(to: view, coordinator: coordinator)
        XCTAssertEqual(view.contentOffset, .zero)
        XCTAssertTrue(view.indexPathsForSelectedItems?.isEmpty ?? true)
    }

    func testNativeScrollDelegateConstrainsDragAndMomentumTargetThenReleasesLock() {
        let grid = MobileDataGrid(data: data, revision: "page", widthKey: UUID().uuidString) { _, _ in }
        let coordinator = grid.makeCoordinator(), view = MobileDataGrid.makeCollectionView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 220, height: 400)
        grid.apply(to: view, coordinator: coordinator)
        XCTAssertTrue(view.isDirectionalLockEnabled)
        view.contentOffset = CGPoint(x: 80, y: 120)
        coordinator.axisLock.begin(at: view.contentOffset, translation: CGPoint(x: 20, y: 5))
        view.contentOffset = CGPoint(x: 180, y: 200)
        coordinator.scrollViewDidScroll(view)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 180, y: 120))
        let refresh = MobileDataGrid(data: data, revision: "refresh", widthKey: grid.widthKey) { _, _ in }
        refresh.apply(to: view, coordinator: coordinator)
        XCTAssertTrue(coordinator.axisLock.isTracking, "A same-object refresh must not unlock an ongoing gesture")
        var target = CGPoint(x: 600, y: 800)
        coordinator.scrollViewWillEndDragging(view, withVelocity: CGPoint(x: 2, y: 1), targetContentOffset: &target)
        XCTAssertEqual(target, CGPoint(x: 600, y: 120))
        coordinator.scrollViewDidEndDragging(view, willDecelerate: true)
        XCTAssertTrue(coordinator.axisLock.isTracking)
        coordinator.scrollViewDidEndDecelerating(view)
        XCTAssertFalse(coordinator.axisLock.isTracking)
        view.contentOffset = CGPoint(x: 180, y: 200)
        XCTAssertEqual(view.contentOffset, CGPoint(x: 180, y: 200))
    }

    func testFullscreenReadableGridRespectsSafeAreaWhileScrollingAndResizing() async throws {
        let selection = MobileFullscreenGridSelection(data: data, revision: "page", widthKey: UUID().uuidString,
                                                      viewport: MobileGridViewport())
        let host = UIHostingController(rootView: MobileFullscreenGrid(selection: selection))
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey() }
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let grid = try XCTUnwrap(descendant(of: UICollectionView.self, in: host.view))
        assertSafeGrid(grid, in: host)
        grid.contentOffset = CGPoint(x: 180, y: 440)
        grid.layoutIfNeeded()
        assertSafeGrid(grid, in: host)

        // Test the resized proposal and asymmetric hardware exclusion on both sides.
        for left: Bool in [true, false] {
            window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left ? 59 : 0, bottom: 21, right: left ? 0 : 59)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            assertSafeGrid(grid, in: host)
        }
    }

    func testFullscreenDismissesUnderlyingInputOnEntryResizeAndLateKeyboardShowThenReleasesGuard() async throws {
        let controller = UIViewController()
        let previousKey = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.makeKeyAndVisible()
        let field = UITextField(frame: CGRect(x: 10, y: 80, width: 180, height: 44))
        controller.view.addSubview(field)
        let guardView = MobileFullscreenInputGuardView(frame: controller.view.bounds)
        defer { guardView.removeFromSuperview(); field.resignFirstResponder(); window.isHidden = true; previousKey?.makeKey() }
        XCTAssertTrue(field.becomeFirstResponder())
        controller.view.addSubview(guardView)
        XCTAssertFalse(field.isFirstResponder, "Fullscreen entry must dismiss a retained search/editor responder")
        try await Task.sleep(for: .milliseconds(100))

        field.becomeFirstResponder()
        guardView.frame.size = CGSize(width: 844, height: 390)
        guardView.setNeedsLayout(); guardView.layoutIfNeeded()
        XCTAssertFalse(field.isFirstResponder, "Rotation must not restore background input")

        field.becomeFirstResponder()
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertFalse(field.isFirstResponder)
        guardView.removeFromSuperview()
        XCTAssertTrue(field.becomeFirstResponder())
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(field.isFirstResponder, "Dismissing fullscreen must restore normal text input")
    }

    private func assertSafeGrid(_ grid: UICollectionView, in host: UIViewController, file: StaticString = #filePath, line: UInt = #line) {
        let frame = grid.convert(grid.bounds, to: host.view)
        let safe = host.view.safeAreaLayoutGuide.layoutFrame
        XCTAssertGreaterThanOrEqual(frame.minY, safe.minY - 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, safe.maxY + 1, file: file, line: line)
        XCTAssertGreaterThan(frame.height, safe.height - 2, file: file, line: line)
        let header = grid.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        XCTAssertEqual(header?.frame.minY, max(0, grid.contentOffset.y), file: file, line: line)
    }

    private func descendant<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(of: type, in: $0) }.first
    }
}
