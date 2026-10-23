import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileTableOptionsPresentationTests: XCTestCase {
    func testExistingOptionsRightAlignedReturnOnlyDismissesAndAdvancedFieldsScrollInLightAndDark() async throws {
        let (controller,draft,_) = try await MobileTableOptionsTests().fixture()
        let host = UIHostingController(rootView: OptionsRefreshHarness(controller: controller, draft: draft))
        let (window,previous) = try mount(host); defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await settle(host); capture(host, "existing-options-dark")
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.text == "original" })
        XCTAssertEqual(field.textAlignment, .right); XCTAssertEqual(field.returnKeyType, .done)
        XCTAssertTrue(field.becomeFirstResponder()); _ = field.delegate?.textFieldShouldReturn?(field); field.sendActions(for: .editingDidEndOnExit)
        try await settle(host); XCTAssertFalse(field.isFirstResponder); XCTAssertFalse(draft.hasChanges); XCTAssertTrue(controller.safetyLock.isEnabled)
        window.overrideUserInterfaceStyle = .light; try await settle(host); capture(host, "existing-options-light")
        let form = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        form.setContentOffset(.init(x: 0,y: max(-form.adjustedContentInset.top,form.contentSize.height-form.bounds.height+form.adjustedContentInset.bottom)), animated: false)
        try await settle(host); capture(host, "existing-options-advanced-light")
        XCTAssertNotNil(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.placeholder == "键块大小" })
        XCTAssertEqual(draft.state.tableOptions.comment, "original")
    }
    func testReloadInvalidatesPresentedOptionsAndDoesNotStageOldValues() async throws {
        let (controller,draft,service) = try await MobileTableOptionsTests().fixture(), epoch = draft.epoch
        let host = UIHostingController(rootView: OptionsRefreshHarness(controller: controller, draft: draft))
        let (window,previous) = try mount(host); defer { window.isHidden = true; previous?.makeKey() }
        try await settle(host); var changed = draft.state.tableOptions; changed.comment = "refreshed"
        await service.setOptions(changed); await controller.load(draft.object)?.value; try await settle(host)
        XCTAssertNotEqual(draft.epoch,epoch); XCTAssertFalse(draft.hasChanges); XCTAssertEqual(draft.state.tableOptions.comment,"refreshed")
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.text == "original" })
        XCTAssertFalse(field.isEnabled); capture(host, "existing-options-expired")
    }
    func testOptionsDraftUsesExistingStructureFooterAndOneCapturedSQLPreview() async throws {
        let (controller,draft,_) = try await MobileTableOptionsTests().fixture()
        var options = draft.state.tableOptions; options.comment = "待提交表注释"; draft.updateOptions(options)
        let plan = draft.plan
        let host = UIHostingController(rootView: MobileSchemaContent(controller: controller,draft: draft))
        let (window,previous) = try mount(host); defer { window.isHidden = true; previous?.makeKey() }
        try await settle(host); capture(host,"existing-options-structure-footer")
        let preview = UIHostingController(rootView: MobileSchemaPendingView(controller: controller,draft: draft,close: {}))
        window.rootViewController = preview; try await settle(preview); capture(preview,"existing-options-pending")
        XCTAssertEqual(plan.statements.count,1); XCTAssertTrue(plan.statements[0].sql.contains("待提交表注释")); XCTAssertEqual(draft.plan,plan)
        XCTAssertFalse(controller.isSubmitting); XCTAssertTrue(controller.safetyLock.isEnabled)
    }
    private func settle(_ host: UIViewController) async throws { try await Task.sleep(for: .milliseconds(550)); host.view.layoutIfNeeded() }
    private func mount(_ host: UIViewController) throws -> (UIWindow,UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark; window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded(); return (window,previous)
    }
    private func capture(_ host: UIViewController,_ name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds,afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(descendants) }
}

private struct OptionsRefreshHarness: View {
    let controller: MobileSchemaController
    let draft: MobileSchemaDraft
    var body: some View {
        MobileExistingTableOptionsView(controller: controller, draft: draft, close: {})
            .accessibilityIdentifier(draft.epoch.uuidString)
    }
}
