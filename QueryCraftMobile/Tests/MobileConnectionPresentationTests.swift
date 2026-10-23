import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileConnectionPresentationTests: XCTestCase {
    func testPausedReadKeepsNativeGridFrameWidthsOffsetAndSelection() async throws {
        let executor = PresentationReadGate(), model = MobileQueryModel(executor: executor)
        model.sql = "SELECT 1"
        await model.execute()?.value
        let host = UIHostingController(rootView: NavigationStack {
            MobileWorkspaceView(model: model, widthKey: UUID().uuidString)
        }.environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(200))
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
        let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
        grid.contentOffset = .init(x: 50, y: 120)
        grid.selectItem(at: .init(item: 3, section: 8), animated: false, scrollPosition: [])
        coordinator.saveViewport(grid)
        let frame = grid.frame, widths = coordinator.widths, offset = grid.contentOffset, selected = grid.indexPathsForSelectedItems
        let refresh = try XCTUnwrap(model.execute())
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await executor.waiting), ContinuousClock.now < deadline { await Task.yield() }
        let waiting = await executor.isWaiting(); XCTAssertTrue(waiting)
        model.setBackgrounded(true)
        await executor.release(); await refresh.value
        model.setBackgrounded(false)
        try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
        XCTAssertEqual(model.errorMessage, MobileConnectionFeedback.paused)
        XCTAssertEqual(grid.frame, frame); XCTAssertEqual(coordinator.widths, widths)
        XCTAssertEqual(grid.contentOffset, offset); XCTAssertEqual(grid.indexPathsForSelectedItems, selected)
        XCTAssertEqual(model.result?.rows.count, 100)
        let calls = await executor.callCount(); XCTAssertEqual(calls, 2, "Returning foreground must not execute SQL again")
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

private actor PresentationReadGate: MobileQueryExecuting {
    private var calls = 0
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func isWaiting() -> Bool { waiting }
    func callCount() -> Int { calls }
    func release() { continuation?.resume(); continuation = nil; waiting = false }
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        calls += 1
        if calls == 2 { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return .init(columns: (0..<20).map { "column_\($0)" }, rows: (0..<100).map { row in (0..<20).map { "\(row):\($0)" } })
    }
}
