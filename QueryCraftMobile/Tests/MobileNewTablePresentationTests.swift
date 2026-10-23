import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileNewTablePresentationTests: XCTestCase {
    func testNewTableStructureIndexesOptionsAndLockedPreviewRenderSameDraft() async throws {
        let (controller,draft) = try MobileNewTableTests().fixture()
        draft.definition.tableName = "mobile_orders"
        let id = draft.definition.editor.addColumn(); var def = try XCTUnwrap(draft.definition.editor.columns.first { $0.id == id }).definition
        def.name = "order_title"; def.comment = "订单标题"; controller.editingContext(draft).updateColumn(id, def, false)
        let index = draft.definition.editor.addIndex(); var idx = try XCTUnwrap(draft.definition.editor.indexes.first { $0.id == index }).definition
        idx.name = "title_idx"; idx.columns = [.init(name: "order_title", sourceColumnID: id)]; draft.definition.editor.updateIndex(id: index, definition: idx)
        draft.definition.options.engine = "InnoDB"; draft.definition.options.characterSet = "utf8mb4"; draft.definition.options.comment = "移动端新建订单表"
        let plan = draft.plan, host = UIHostingController(rootView: MobileNewTableView(controller: controller, draft: draft))
        let (window,previous) = try mount(host); defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await settle(host); capture(host, name: "new-table-structure")
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.text == "mobile_orders" })
        XCTAssertEqual(field.textAlignment, .right); XCTAssertEqual(field.returnKeyType, .done)
        XCTAssertTrue(field.becomeFirstResponder()); _ = field.delegate?.textFieldShouldReturn?(field)
        field.sendActions(for: .editingDidEndOnExit); try await settle(host)
        XCTAssertFalse(field.isFirstResponder); XCTAssertFalse(controller.isSubmitting); XCTAssertTrue(controller.safetyLock.isEnabled)
        draft.definition.selectedTab = .indexes; try await settle(host); capture(host, name: "new-table-indexes")
        XCTAssertEqual(descendants(host.view).compactMap { $0 as? UISegmentedControl }.first?.selectedSegmentIndex, 1)
        draft.definition.selectedTab = .options; try await settle(host); capture(host, name: "new-table-options")
        XCTAssertEqual(descendants(host.view).compactMap { $0 as? UISegmentedControl }.first?.selectedSegmentIndex, 2)
        XCTAssertNotNil(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.text == "InnoDB" })
        XCTAssertEqual(draft.plan, plan); XCTAssertGreaterThan(host.view.bounds.height, 400)
        window.overrideUserInterfaceStyle = .light; try await settle(host); capture(host, name: "new-table-options-light")
        let list = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        list.setContentOffset(CGPoint(x: 0, y: max(-list.adjustedContentInset.top, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)), animated: false)
        try await settle(host); capture(host, name: "new-table-advanced-light")
        XCTAssertNotNil(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.placeholder == "键块大小" })
        window.overrideUserInterfaceStyle = .dark
        let preview = UIHostingController(rootView: MobileNewTableConfirmation(controller: controller, draft: draft, plan: plan))
        window.rootViewController = preview; try await settle(preview); capture(preview, name: "new-table-preview-locked")
        XCTAssertEqual(draft.plan, plan); XCTAssertFalse(draft.hasCompleted); XCTAssertTrue(controller.safetyLock.isEnabled)
    }
    func testNewColumnFormReturnDismissesWithoutCreatingOrStagingAndUnknownViewRetainsDefinition() async throws {
        let service = NewTableFixture(), (controller,draft) = try MobileNewTableTests().fixture(service)
        let item = try XCTUnwrap(draft.definition.editor.columns.first), plan = draft.plan
        let selection = MobileSchemaEditSelection(itemID: item.id, epoch: draft.epoch, section: .columns)
        let host = UIHostingController(rootView: MobileSchemaColumnEditor(context: controller.editingContext(draft), selection: selection, close: {}))
        let (window,previous) = try mount(host); defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await settle(host); capture(host, name: "new-table-column")
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.text == "id" })
        XCTAssertTrue(field.becomeFirstResponder()); _ = field.delegate?.textFieldShouldReturn?(field); field.sendActions(for: .editingDidEndOnExit)
        try await settle(host); XCTAssertFalse(field.isFirstResponder); XCTAssertEqual(draft.plan, plan)
        controller.safetyLock.disable(); await service.setMode(.unknown); await controller.submit(draft, plan: plan)?.value
        let uncertain = UIHostingController(rootView: MobileNewTableView(controller: controller, draft: draft))
        window.rootViewController = uncertain; try await settle(uncertain); capture(uncertain, name: "new-table-unknown")
        XCTAssertTrue(draft.needsVerification); XCTAssertFalse(controller.canEdit(draft)); XCTAssertEqual(draft.plan, plan)
    }
    func testCatalogEntryFitsExistingFooterAndNativeWorkspacePresentsDraft() async throws {
        let profile = MobileConnectionProfile(id: UUID(), name: "owned catalog", host: "fake", port: 1, username: "fake", database: "db", tlsMode: .disabled, remembersPassword: false, requiresPassword: false)
        let app = MobileApplicationModel(service: ActionFixture()); app.open(profile)
        let workspace = try XCTUnwrap(app.workspace); await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        let host = UIHostingController(rootView: MobileConnectionWorkspaceView(app: app, workspace: workspace))
        let (window,previous) = try mount(host); defer { window.isHidden = true; previous?.makeKey(); workspace.cancelAll() }
        try await settle(host); capture(host, name: "new-table-catalog-entry")
        workspace.newTable.present(database: "db"); try await settle(host)
        XCTAssertNotNil(host.presentedViewController); XCTAssertNotNil(workspace.newTable.request)
        capture(host.presentedViewController ?? host, name: "new-table-native-sheet")
        workspace.newTable.dismiss(); try await settle(host)
        XCTAssertNil(workspace.newTable.request)
    }
    private func settle(_ host: UIViewController) async throws { try await Task.sleep(for: .milliseconds(550)); host.view.layoutIfNeeded() }
    private func mount(_ host: UIViewController) throws -> (UIWindow,UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark; window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded(); return (window,previous)
    }
    private func capture(_ host: UIViewController,name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
