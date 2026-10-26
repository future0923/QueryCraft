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
            .environment(\.horizontalSizeClass, .regular).mobileAppearance())
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

    func testCompactNavigationUsesOneNativeTabBarWithContentBehindIt() async throws {
        let app = MobileApplicationModel(repository: LayoutLibrary(), passwords: LayoutPasswords(), service: LayoutService(objectCount: 60))
        let draft = MobileConnectionDraft(); draft.name = "Native navigation"; draft.database = "db"
        app.open(try draft.profile())
        let workspace = try XCTUnwrap(app.workspace)
        await workspace.browser.loadDatabases().value; await workspace.browser.loadObjects()?.value
        workspace.query.sql = "SELECT preserved_draft"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.interfaceOrientation
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: MobileConnectionWorkspaceView(app: app, workspace: workspace)
            .environment(\.horizontalSizeClass, .compact).mobileAppearance())
        window.rootViewController = host; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        if UIDevice.current.userInterfaceIdiom == .phone { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        defer {
            window.endEditing(true); window.isHidden = true; previous?.makeKey(); workspace.cancelAll()
            if UIDevice.current.userInterfaceIdiom == .phone { scene.requestGeometryUpdate(.iOS(interfaceOrientations: original.isLandscape ? .landscape : .portrait)) }
        }
        try await Task.sleep(for: .milliseconds(600)); host.view.layoutIfNeeded()
        let tabs = try XCTUnwrap(controller(UITabBarController.self, in: host))
        for (tab, index) in [(MobileApplicationModel.WorkspaceTab.tables, 0), (.query, 1), (.views, 2), (.tables, 0)] {
            app.selectTab(tab)
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            XCTAssertFalse(tabs.tabBar.isHidden)
            XCTAssertEqual(tabs.tabBar.items?.count, 3)
            let bars = descendants(host.view).compactMap { $0 as? UITabBar }.filter { !$0.isHidden && $0.alpha > 0 }
            XCTAssertEqual(bars.count, 1, "Keep exactly one native navigation bar")
            if tab != .query {
                let list = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.max { $0.bounds.height < $1.bounds.height })
                let listFrame = list.convert(list.bounds, to: host.view), barFrame = tabs.tabBar.convert(tabs.tabBar.bounds, to: host.view)
                let attachment = XCTAttachment(string: "list=\(listFrame), bar=\(barFrame), inset=\(list.adjustedContentInset)")
                attachment.name = "native-tab-viewport-" + tab.rawValue; attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThanOrEqual(listFrame.maxY, barFrame.midY, "List must draw beneath the native tab bar without an opaque footer")
            }
            XCTAssertEqual(tabs.selectedIndex, index)
            XCTAssertEqual(workspace.query.sql, "SELECT preserved_draft")
            capture(host, name: "native-navigation-" + tab.rawValue)
        }
        // SwiftUI may mount its native search field after the tab transition.
        var searchField: UITextField?
        for _ in 0..<30 {
            searchField = view(UISearchBar.self, in: host.view)?.searchTextField
                ?? descendants(host.view).compactMap { $0 as? UISearchTextField }.first
            if searchField != nil { break }
            try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        }
        if let search = searchField {
            XCTAssertLessThan(search.convert(search.bounds, to: host.view).midY, host.view.bounds.height / 2)
            XCTAssertTrue(search.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(350)); host.view.layoutIfNeeded()
            capture(host, name: "native-navigation-keyboard")
            window.endEditing(true)
        } else { XCTFail("Catalog search must remain available at the top") }
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ host: UIViewController, name: String) {
        let format = UIGraphicsImageRendererFormat(); format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
private struct LayoutService: MobileSQLServicing {
    var objectCount = 0
    func databases(configuration: MobileSQLConfiguration) async throws -> [String] { ["db"] }
    func objects(configuration: MobileSQLConfiguration, database: String, search: String, kind: MobileDatabaseObject.Kind?) async throws -> MobileObjectCatalog {
        .init(objects: (0..<objectCount).map { .init(database: database, name: String(format: "admin_table_%03d", $0), kind: kind ?? .table, comment: "目录滚动内容") }, hasMore: false)
    }
    func columns(configuration: MobileSQLConfiguration, object: MobileDatabaseObject) async throws -> [MobileTableColumn] { [] }
    func page(configuration: MobileSQLConfiguration, object: MobileDatabaseObject, columns: [MobileTableColumn], offset: Int, size: Int, sortColumn: String?, ascending: Bool, filter: WorkspaceDatabaseDataFilter) async throws -> MobileTableSnapshot {
        .init(object: object, preview: .init(result: .init()), columns: columns, offset: offset, pageSize: size, hasNextPage: false, hasStableOrder: true)
    }
}
