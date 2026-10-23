import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileSurfaceEditingPresentationTests: XCTestCase {
    func testFullscreenTapEditsAndKeyboardSurvivesNotificationsAndResizeThenGuardResumes() async throws {
        let fixture = SurfaceEditingFixture(), source = fixture.source, viewport = MobileGridViewport()
        let selection = MobileFullscreenGridSelection(data: source.data, revision: source.revision, widthKey: "table",
            viewport: viewport, pageContext: source.snapshot.identity.page, source: source)
        viewport.activeOwner = selection.id
        let host = UIHostingController(rootView: MobileFullscreenGrid(selection: selection))
        let (window, previous) = try show(host)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(150))
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
        let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
        let horizontalOffset = min(50, max(0, grid.contentSize.width - grid.bounds.width))
        grid.contentOffset = .init(x: horizontalOffset, y: 300); coordinator.saveViewport(grid)
        let widths = coordinator.widths, offset = grid.contentOffset
        coordinator.collectionView(grid, didSelectItemAt: .init(item: 1, section: 1))
        try await Task.sleep(for: .milliseconds(350))
        let sheet = try XCTUnwrap(host.presentedViewController)
        let input = try XCTUnwrap(descendants(sheet.view).compactMap { $0 as? UITextView }.first { $0.text == "before" })
        XCTAssertTrue(input.becomeFirstResponder())
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(input.isFirstResponder, "Fullscreen guard must allow its own edit sheet")
        let guardView = try XCTUnwrap(descendants(host.view).compactMap { $0 as? MobileFullscreenInputGuardView }.first)
        guardView.frame.size = .init(width: 844, height: 390); guardView.setNeedsLayout(); guardView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(75)); XCTAssertTrue(input.isFirstResponder)
        _ = input.delegate?.textView?(input, shouldChangeTextIn: .init(location: input.text.utf16.count, length: 0), replacementText: "\n")
        XCTAssertFalse(input.isFirstResponder); XCTAssertEqual(input.text, "before")
        sheet.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let backgroundInput = UITextField(frame: .init(x: 10, y: 100, width: 150, height: 40))
        host.view.addSubview(backgroundInput)
        XCTAssertTrue(backgroundInput.becomeFirstResponder())
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        XCTAssertFalse(backgroundInput.isFirstResponder, "Guard must resume after its real sheet is dismissed")
        backgroundInput.removeFromSuperview()
        XCTAssertEqual(coordinator.widths, widths)
        XCTAssertEqual(grid.contentOffset.x, offset.x, accuracy: 1)
        XCTAssertEqual(grid.contentOffset.y, offset.y, accuracy: 1)
        let edit = try source.edit(row: 0, column: 1)
        try fixture.changes.stage(edit.request, text: "live pending", mode: .value)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(coordinator.parent.data.cell(row: 0, column: 1), .text("live pending"))
        XCTAssertTrue(coordinator.parent.data.pendingCells.contains(.init(row: 0, column: 1)))
        XCTAssertEqual(grid.contentOffset.x, offset.x, accuracy: 1); XCTAssertEqual(grid.contentOffset.y, offset.y, accuracy: 1)
        XCTAssertEqual(coordinator.widths, widths)
        XCTAssertTrue(fixture.changes.safetyLock.isEnabled)
    }

    func testFullscreenPendingAccessibilityUsesSameModelAndNoPermanentToolbar() async throws {
        let fixture = SurfaceEditingFixture(), source = fixture.source
        try fixture.changes.stage(source.edit(row: 0, column: 1).request, text: "pending", mode: .value)
        let selection = MobileFullscreenGridSelection(data: source.data, revision: source.revision, widthKey: "table",
            viewport: MobileGridViewport(), pageContext: source.snapshot.identity.page, source: source)
        selection.viewport.activeOwner = selection.id
        let host = UIHostingController(rootView: MobileFullscreenGrid(selection: selection))
        let (window, previous) = try show(host)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(150))
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
        let action = try XCTUnwrap(grid.cellForItem(at: .init(item: 1, section: 1))?.accessibilityCustomActions?.first)
        XCTAssertEqual(action.name, "查看待提交改动")
        let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
        coordinator.parent.onShowPendingChanges?()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(host.presentedViewController)
        XCTAssertEqual(fixture.changes.changeCount, 1); XCTAssertTrue(fixture.changes.safetyLock.isEnabled)
        XCTAssertTrue(descendants(host.view).compactMap { $0 as? UIToolbar }.isEmpty)
    }

    func testRecordsRetainScrollAcrossRecreationAndUseLiveStagedValues() async throws {
        let fixture = SurfaceEditingFixture(), position = RecordTestPosition()
        position.row = 70
        let root = RecordScrollHarness(source: fixture.source, position: position)
        let host = UIHostingController(rootView: root)
        let (window, previous) = try show(host)
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(200))
        let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        XCTAssertGreaterThan(scroll.contentOffset.y, 1000)
        let oldPosition = position.row
        host.rootView = RecordScrollHarness(source: fixture.source, position: position)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(position.row, oldPosition)
        let rebuilt = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.first)
        XCTAssertFalse(rebuilt === scroll, "Mode switch must exercise a newly created scroll view")
        XCTAssertGreaterThan(rebuilt.contentOffset.y, 1000)
        let edit = try fixture.source.edit(row: 70, column: 1)
        try fixture.changes.stage(edit.request, text: "record pending", mode: .value)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(fixture.source.data.cell(row: 70, column: 1), .text("record pending"))
        XCTAssertEqual(position.row, oldPosition)
    }

    func testRecordInspectorSharesAllMetadataAndCapturedGeneration() async throws {
        let fixture = SurfaceEditingFixture(), selection = MobileRecordSelection(row: 0, source: fixture.source)
        let host = UIHostingController(rootView: MobileRecordInspector(selection: selection))
        let (window, previous) = try show(host)
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(host.view)
        let capture = try fixture.source.edit(row: 0, column: 1)
        try fixture.changes.stage(capture.request, text: "from record", mode: .value)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(selection.source.data.cell(row: 0, column: 1), .text("from record"))
        XCTAssertTrue(selection.source.snapshot.editing === fixture.changes)
        fixture.source.receive(fixture.snapshot(revision: "refresh", raw: "new page"))
        XCTAssertNotEqual(selection.generation, fixture.source.generation)
        XCTAssertThrowsError(try capture.validateContext())
    }

    private func show<V: View>(_ host: UIHostingController<V>) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, previous)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor @Observable private final class RecordTestPosition { var row: Int? }
private struct RecordScrollHarness: View {
    private let identity = UUID()
    let source: MobileResultSource
    @Bindable var position: RecordTestPosition
    var body: some View { MobileRecordList(data: source.data, revision: source.revision, scrollID: $position.row) { _ in }.id(identity) }
}
