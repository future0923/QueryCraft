import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileSchemaPresentationTests: XCTestCase {
    func testNativeFieldInputAlignsRightReturnDismissesAndDoesNotStage() async throws {
        let (controller, object) = MobileSchemaStateTests().fixture(); await controller.load(object)?.value
        let draft = controller.draft(for: object), item = try XCTUnwrap(draft.state.columns.last)
        let selection = MobileSchemaEditSelection(itemID: item.id, epoch: draft.epoch, section: .columns)
        let host = UIHostingController(rootView: MobileSchemaColumnEditor(controller: controller, draft: draft, selection: selection, close: {}))
        let (window, previous) = try mount(host); defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.text == "title" })
        capture(host, name: "schema-column-dark"); XCTAssertEqual(field.textAlignment, .right); XCTAssertEqual(field.returnKeyType, .done)
        XCTAssertTrue(field.becomeFirstResponder()); try await Task.sleep(for: .milliseconds(80))
        _ = field.delegate?.textFieldShouldReturn?(field); field.sendActions(for: .editingDidEndOnExit)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertFalse(field.isFirstResponder)
        XCTAssertFalse(draft.hasChanges); XCTAssertTrue(controller.safetyLock.isEnabled)
    }
    func testNativeSchemaGridListSwitchKeepsStagedModelAndViewport() async throws {
        let (controller, object) = MobileSchemaStateTests().fixture(); await controller.load(object)?.value
        let draft = controller.draft(for: object); try MobileSchemaStateTests().stage(draft)
        let plan = draft.plan, ids = draft.state.columns.map(\.id)
        let host = UIHostingController(rootView: MobileSchemaContent(controller: controller, draft: draft))
        let (window, previous) = try mount(host); defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.accessibilityIdentifier == "databaseGrid" })
        capture(host, name: "schema-grid-dark"); let viewport = grid.frame; XCTAssertGreaterThan(viewport.height, 100)
        draft.presentation = .list; try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
        capture(host, name: "schema-list-dark"); XCTAssertEqual(draft.plan, plan); draft.presentation = .table
        try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
        let restored = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.accessibilityIdentifier == "databaseGrid" })
        XCTAssertEqual(restored.frame, viewport); XCTAssertEqual(draft.state.columns.map(\.id), ids); XCTAssertEqual(draft.plan, plan)
        XCTAssertGreaterThan(restored.visibleCells.count, 0)
    }
    private func mount(_ host: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark; window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded(); return (window, previous)
    }
    private func capture(_ host: UIViewController, name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
