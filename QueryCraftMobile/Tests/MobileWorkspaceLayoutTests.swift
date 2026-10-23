import QueryCraftMobileCore
import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileWorkspaceLayoutTests: XCTestCase {
    func testRegularSidebarOwnsTopEdgeAndSurvivesTabChanges() async throws {
        let app = MobileApplicationModel(repository: LayoutLibrary(), passwords: LayoutPasswords(), service: LayoutService())
        let draft = MobileConnectionDraft(); draft.name = "Layout"; draft.database = "db"
        app.open(try draft.profile())
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value
        await workspace.browser.loadObjects()?.value
        workspace.query.sql = "SELECT preserved_draft"
        let host = UIHostingController(rootView: MobileConnectionWorkspaceView(app: app, workspace: workspace)
            .environment(\.horizontalSizeClass, .regular))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previousKey?.makeKey(); workspace.cancelAll() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let split = try XCTUnwrap(controller(UISplitViewController.self, in: host))
        XCTAssertFalse(hasTabAncestor(split), "A root tab bar must not reserve space above the sidebar")
        XCTAssertNil(controller(UITabBarController.self, in: host), "Regular navigation must use its title menu without a tab row")
        // A forced regular-width branch on a compact-height phone still receives
        // native compact status-bar insets. Check top geometry in real regular
        // height; hierarchy assertions above cover both simulator families.
        if !split.isCollapsed, scene.traitCollection.verticalSizeClass == .regular {
            let sidebar = try XCTUnwrap(split.viewControllers.first)
            let bar = try XCTUnwrap(view(UINavigationBar.self, in: sidebar.view))
            let top = bar.convert(bar.bounds, to: host.view).minY
            XCTAssertLessThanOrEqual(top, host.view.safeAreaInsets.top + 12, "Sidebar toolbar must align to the system top safe area")
        }
        if !split.isCollapsed, scene.traitCollection.verticalSizeClass == .regular {
            for (style, name) in [(UIUserInterfaceStyle.dark, "dark"), (.light, "light")] {
                window.overrideUserInterfaceStyle = style
                try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image); attachment.name = "workspace-sidebar-" + name
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for tab in [MobileApplicationModel.WorkspaceTab.query, .views, .tables] {
            app.selectTab(tab)
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(controller(UISplitViewController.self, in: host) === split)
            XCTAssertFalse(hasTabAncestor(split))
            XCTAssertNil(controller(UITabBarController.self, in: host))
            XCTAssertEqual(workspace.query.sql, "SELECT preserved_draft")
        }
    }

    private func controller<T: UIViewController>(_ type: T.Type, in root: UIViewController) -> T? {
        if let match = root as? T { return match }
        return root.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }
    private func view<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { self.view(type, in: $0) }.first
    }
    private func hasTabAncestor(_ controller: UIViewController) -> Bool {
        var parent = controller.parent
        while let current = parent {
            if current is UITabBarController { return true }
            parent = current.parent
        }
        return false
    }
}

@MainActor private final class LayoutLibrary: MobileLibraryPersisting {
    func load() throws -> MobileLibraryState { .init() }
    func write(_ state: MobileLibraryState) throws { }
}
@MainActor private struct LayoutPasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws { }
}
private struct LayoutService: MobileMySQLServicing {
    func databases(configuration: MariaDBTransportConfiguration) async throws -> [String] { ["db"] }
    func objects(configuration: MariaDBTransportConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        .init(objects: [], hasMore: false)
    }
    func columns(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] { [] }
    func page(configuration: MariaDBTransportConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        .init(object: object, preview: .init(result: .init()), columns: columns, offset: offset, pageSize: size, hasNextPage: false, hasStableOrder: true)
    }
}
