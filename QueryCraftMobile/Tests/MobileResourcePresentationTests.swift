import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileResourcePresentationTests: XCTestCase {
    func testNativeResourceRefreshKeepsGridFrameAndVisibleRows() async throws {
        let service = ResourcePresentationService()
        let profile = MobileConnectionProfile(id: UUID(), name: "Elasticsearch 验证", host: "127.0.0.1", port: 9200, username: "", database: "", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: .elasticsearch)
        let model = MobileResourceModel(profile: profile, password: nil, service: service)
        await model.load()?.value; await model.loadCatalog()?.value
        model.select(.init(name: "admin_user", kind: "索引")); await model.loadDetails()?.value
        let app = MobileApplicationModel()
        let host = UIHostingController(rootView: MobileResourceWorkspaceView(app: app, model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(200))
        let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
        let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
        let frame = grid.frame, widths = coordinator.widths
        XCTAssertEqual(coordinator.parent.data.rows.count, 100)
        await service.holdNext()
        let request = try XCTUnwrap(model.loadDetails()); await service.waitUntilHeld()
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(grid.frame, frame); XCTAssertEqual(coordinator.widths, widths)
        XCTAssertEqual(coordinator.parent.data.rows.count, 100)
        await service.release(); await request.value
        host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(grid.frame, frame); XCTAssertEqual(coordinator.widths, widths)
        if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: directory.appending(path: "elasticsearch-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

private actor ResourcePresentationService: MobileResourceServicing {
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func holdNext() { hold = true }
    func waitUntilHeld() async { if continuation != nil { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { continuation?.resume(); continuation = nil }
    func scopes() async throws -> [String] { ["Elasticsearch"] }
    func catalog(scope: String, cursor: UInt64, search: String) async throws -> MobileResourceCatalog { .init(resources: [.init(name: "admin_user", kind: "索引"), .init(name: "events", kind: "数据流")]) }
    func details(resource: MobileResource, scope: String, offset: Int, cursor: UInt64) async throws -> MobileResourceDetails {
        if hold {
            hold = false
            await withCheckedContinuation { continuation = $0; for waiter in waiters { waiter.resume() }; waiters = [] }
        }
        return .init(data: .init(columns: ["_id", "_index", "_source"], rows: (1...100).map { [String($0), "admin_user", "{\"name\":\"用户 \($0)\",\"active\":true}"] }),
            structure: .init(columns: ["字段", "类型"], rows: [["name", "text"], ["active", "boolean"]]), status: "只读 · 第 1–100 条 · 最多浏览前 10,000 条", hasNext: true)
    }
}
