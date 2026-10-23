import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileTableActionPresentationTests: XCTestCase {
    func testNativeAutoValueAndConfirmationAlignRightAndKeyboardReturnDismissesOnlyInput() async throws {
        let fixture = await MobileTableActionStateTests().workspace()
        let controller = fixture.tableActions, object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
        controller.prepare(.setAutoIncrement, object: object)
        let draft = try XCTUnwrap(controller.request)
        let (host, window, previous) = try mount(controller, draft)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        let fields = descendants(host.view).compactMap { $0 as? UITextField }
        let value = try XCTUnwrap(fields.first { $0.text == "1" })
        let confirmation = try XCTUnwrap(fields.first { $0.placeholder == "t" })
        XCTAssertEqual(value.textAlignment, .right); XCTAssertEqual(confirmation.textAlignment, .right)
        XCTAssertEqual(value.returnKeyType, .done); XCTAssertEqual(confirmation.returnKeyType, .done)
        XCTAssertEqual(draft.info?.nextAutoIncrement, "43"); XCTAssertFalse(draft.isInspecting)
        for field in [value, confirmation] {
            XCTAssertTrue(field.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(80))
            _ = field.delegate?.textFieldShouldReturn?(field)
            field.sendActions(for: .editingDidEndOnExit) // UIKit Return dispatches this control event.
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertFalse(field.isFirstResponder, "Return must dismiss \(field.accessibilityIdentifier ?? field.placeholder ?? "input")")
            XCTAssertFalse(controller.isSubmitting); XCTAssertFalse(draft.hasCompleted)
        }
        XCTAssertFalse(draft.isConfirmed); XCTAssertTrue(controller.safetyLock.isEnabled)
    }
    func testRenameAndDestructiveConfirmationUseCommonRulesAndViewNeverAutoSubmits() async throws {
        let writer = ActionWriter(), workspace = await MobileTableActionStateTests().workspace(writer: writer)
        let controller = workspace.tableActions, object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
        controller.prepare(.rename, object: object)
        let rename = try XCTUnwrap(controller.request)
        XCTAssertNil(rename.statement); XCTAssertFalse(rename.canSubmit)
        rename.input = "新`表"; XCTAssertTrue(rename.canSubmit)
        XCTAssertEqual(rename.statement?.sql, "RENAME TABLE `db`.`t` TO `db`.`新``表`")
        controller.dismiss(); controller.prepare(.truncate, object: object)
        let draft = try XCTUnwrap(controller.request)
        let (host, window, previous) = try mount(controller, draft)
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        draft.confirmation = "T"; XCTAssertFalse(draft.canSubmit)
        draft.confirmation = "t"; XCTAssertTrue(draft.canSubmit)
        XCTAssertTrue(controller.safetyLock.isEnabled)
        let calls = await writer.calls; XCTAssertEqual(calls, 0)
    }
    private func mount(_ controller: MobileTableActionController, _ draft: MobileTableActionDraft) throws -> (UIViewController, UIWindow, UIWindow?) {
        let host = UIHostingController(rootView: MobileTableActionView(controller: controller, draft: draft).environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        return (host, window, previous)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
