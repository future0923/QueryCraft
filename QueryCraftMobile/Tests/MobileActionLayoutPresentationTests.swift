import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileActionLayoutPresentationTests: XCTestCase {
    func testTransferUsesNavigationActionsAndFullHeightScrollableForm() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MobileTransferModel(profiles: [], manager: DataTransferManager(historyURL: directory.appending(path: "history.json")),
            library: DataTransferLibraryStore(url: directory.appending(path: "tasks.json")), resolve: { _, _ in throw MobileQueryError.invalidConnection })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey(); model.background(true) }
        for (name, size, font) in [
            ("narrow", CGSize(width: 320, height: 568), DynamicTypeSize.large),
            ("landscape", CGSize(width: 700, height: 380), .large),
            ("split-large-text", CGSize(width: 375, height: 650), .accessibility1),
            ("full", window.bounds.size, .large)
        ] {
            let host = UIHostingController(rootView: MobileTransferView(model: model).mobileAppearance().environment(\.dynamicTypeSize, font))
            container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
            host.view.frame = CGRect(origin: .zero, size: size)
            try await settle(host)
            let scroll = try formScroll(host)
            assertFillsBottom(scroll, host: host)
            let bars = descendants(host.view).compactMap { $0 as? UINavigationBar }
            let navigationItems = bars.flatMap { $0.items ?? [] }
            let items = navigationItems.flatMap { item in
                (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
            }
            let details = items.map { "id=\($0.accessibilityIdentifier ?? "nil") title=\($0.title ?? "nil") label=\($0.accessibilityLabel ?? "nil") menu=\($0.menu?.title ?? "nil")" }.joined(separator: "\n")
            let attachment = XCTAttachment(string: details); attachment.name = "transfer-navigation-items-" + name; attachment.lifetime = .keepAlways; add(attachment)
            capture(host, name: "transfer-navigation-" + name)
            XCTAssertFalse(items.isEmpty, "The operation menu must remain in the navigation bar: " + details)
            let bar = try XCTUnwrap(bars.first)
            XCTAssertLessThan(bar.convert(bar.bounds, to: host.view).midY, 140)
            let before = scroll.frame
            model.message = "连接读取失败，请检查地址与权限后重试。原有配置保留。"
            try await settle(host)
            XCTAssertEqual(scroll.frame, before, "Error feedback must not resize the form viewport")
            capture(host, name: "transfer-actions-" + name)
            let offset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await settle(host)
            assertFillsBottom(scroll, host: host)
            capture(host, name: "transfer-bottom-" + name)
            model.message = nil
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        XCTAssertFalse(model.canPrepare); XCTAssertTrue(model.safetyLock.isEnabled); XCTAssertTrue(model.manager.runs.isEmpty)
    }

    func testNewTableFeedbackScrollsAndKeyboardDoesNotCreateActionPanel() async throws {
        let service = NewTableFixture(), (controller, draft) = try MobileNewTableTests().fixture(service)
        let host = UIHostingController(rootView: MobileNewTableView(controller: controller, draft: draft).mobileAppearance())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await settle(host)
        let scroll = try formScroll(host)
        assertFillsBottom(scroll, host: host)
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(field.becomeFirstResponder()); try await settle(host)
        XCTAssertTrue(field.isFirstResponder)
        capture(host, name: "new-table-actions-keyboard")
        window.endEditing(true); try await settle(host)
        assertFillsBottom(scroll, host: host)
        XCTAssertTrue(controller.safetyLock.isEnabled); XCTAssertFalse(draft.hasCompleted)
    }

    private func formScroll(_ host: UIViewController) throws -> UIScrollView {
        try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }.max { $0.bounds.height < $1.bounds.height })
    }
    private func assertFillsBottom(_ scroll: UIScrollView, host: UIViewController, file: StaticString = #filePath, line: UInt = #line) {
        let frame = scroll.convert(scroll.bounds, to: host.view)
        XCTAssertGreaterThanOrEqual(frame.maxY - scroll.adjustedContentInset.bottom,
            host.view.safeAreaLayoutGuide.layoutFrame.maxY - 2, "A fixed bottom panel must not consume the form viewport", file: file, line: line)
    }
    private func settle(_ host: UIViewController) async throws { try await Task.sleep(for: .milliseconds(350)); host.view.layoutIfNeeded() }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ host: UIViewController, name: String) {
        let format = UIGraphicsImageRendererFormat(); format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
