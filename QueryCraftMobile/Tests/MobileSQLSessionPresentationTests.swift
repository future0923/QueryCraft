import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor final class MobileSQLSessionPresentationTests: XCTestCase {
    func testCachePagesRetainGridFrameAndWriteConfirmationRendersActualCapturedSQL() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_MYSQL_PORT"] != nil else { throw XCTSkip("Requires the isolated MySQL fixture") }
        let model = MobileQueryModel(), config = try MobileSchemaIntegrationTests().config()
        model.port = String(config.port); model.username = config.username; model.password = config.password ?? ""
        model.database = config.database ?? ""; model.tlsMode = .required
        model.sql = "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<999) SELECT n AS id, CONCAT('缓存记录 ',n) AS name FROM seq ORDER BY n"
        await model.execute()?.value
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.cachedRowCount, 999)
        let host = UIHostingController(rootView: NavigationStack {
            MobileWorkspaceView(model: model, widthKey: "sql-session-native").environment(\.scenePhase, .active)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        let frame = grid.convert(grid.bounds, to: host.view)
        await model.pageCache(1)?.value
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        XCTAssertEqual(model.cacheOffset, 500)
        let current = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        XCTAssertEqual(current.convert(current.bounds, to: host.view), frame)
        for (style, name) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) })
            attachment.name = "query-cache-page-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        model.sql = "UPDATE session_confirmation_preview SET name='用户核对的内容' WHERE id=42;"
        model.executionInput.selection = .init(location: 0, length: 0)
        // Let the native editor receive this SwiftUI binding update before its
        // capture validates actual text and selection. Stale UIKit text must fail.
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        await model.execute()?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.sqlConfirmation?.sql, model.sql)
        try await Task.sleep(for: .milliseconds(650)); host.view.layoutIfNeeded()
        let presented = try XCTUnwrap(host.presentedViewController)
        presented.view.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: presented.view.bounds).image { _ in presented.view.drawHierarchy(in: presented.view.bounds, afterScreenUpdates: true) })
        attachment.name = "sql-write-captured-confirmation"; attachment.lifetime = .keepAlways; add(attachment)
        let visible = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        visible.name = "sql-write-confirmation-visible-window"; visible.lifetime = .keepAlways; add(visible)
        model.sqlConfirmation = nil
        await model.disconnectSQL()?.value
    }
}
