import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileRedisTypePresentationTests: XCTestCase {
    func testTypeSpecificNativeContentAndRefreshFailuresAtPhoneAndPadSizes() async throws {
        let service = RedisTypePresentationService()
        let profile = MobileConnectionProfile(id: UUID(), name: "测试", host: "127.0.0.1", port: 6379, username: "", database: "0", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: .redis)
        let model = MobileResourceModel(profile: profile, password: nil, service: service)
        await model.load()?.value; await model.loadCatalog()?.value
        let host = UIHostingController(rootView: MobileResourceWorkspaceView(app: MobileApplicationModel(), model: model).mobileAppearance())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); model.cancel() }
        try await settle(host)
        try capture(window, "catalog-dark")
        window.overrideUserInterfaceStyle = .light
        let lightHost = UIHostingController(rootView: MobileResourceWorkspaceView(app: MobileApplicationModel(), model: model).mobileAppearance())
        window.rootViewController = lightHost
        try await Task.sleep(for: .milliseconds(500)); lightHost.view.layoutIfNeeded()
        try capture(window, "catalog-light")
        window.rootViewController = host
        try await settle(host)
        model.selectScope("1"); await model.loadCatalog()?.value; try await settle(host)
        XCTAssertEqual(model.scope, "1"); try capture(window, "catalog-db1")
        model.selectScope("0"); await model.loadCatalog()?.value
        window.overrideUserInterfaceStyle = .dark
        model.select(.init(name: "string", kind: "key")); await model.loadDetails()?.value
        try await settle(host)
        let value = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "redisStringText" })
        XCTAssertEqual(value.text, "你好 Redis\n第二行，不需要位置列。")
        XCTAssertFalse(value.isEditable); XCTAssertTrue(value.isSelectable)
        XCTAssertFalse(descendants(host.view).contains { ($0 as? UICollectionView)?.delegate is MobileDataGrid.Coordinator })
        let frame = value.frame
        await service.holdNext()
        let refresh = try XCTUnwrap(model.loadDetails()); await service.waitUntilHeld()
        try await settle(host)
        XCTAssertEqual(value.text, "你好 Redis\n第二行，不需要位置列。"); XCTAssertEqual(value.frame, frame)
        try capture(window, "string-loading")
        await service.release(fail: true); await refresh.value; try await settle(host)
        XCTAssertNotNil(model.detailError); XCTAssertEqual(value.frame, frame)
        XCTAssertEqual(value.text, "你好 Redis\n第二行，不需要位置列。")
        await model.loadDetails()?.value; try await settle(host); XCTAssertNil(model.detailError)
        try capture(window, "string")
        // A late String response must never replace the newly selected Hash.
        await service.holdNext()
        let stale = try XCTUnwrap(model.loadDetails()); await service.waitUntilHeld()
        model.select(.init(name: "hash", kind: "key")); await model.loadDetails()?.value
        await service.release(fail: false); await stale.value; try await settle(host)
        XCTAssertEqual(model.details?.redisType, .hash)
        for (type, columns) in [("hash", ["字段", "值"]), ("list", ["索引", "值"]), ("set", ["成员"]), ("zset", ["成员", "分数"]), ("stream", ["entryID", "fields"])] {
            model.select(.init(name: type, kind: "key")); await model.loadDetails()?.value; try await settle(host)
            let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
            let coordinator = try XCTUnwrap(grid.delegate as? MobileDataGrid.Coordinator)
            XCTAssertEqual(coordinator.parent.data.columns, columns)
            XCTAssertFalse(descendants(host.view).contains { $0.accessibilityIdentifier == "redisStringText" })
            try capture(window, type)
        }
        model.select(.init(name: "long", kind: "key")); await model.loadDetails()?.value; try await settle(host)
        let longText = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "redisStringText" })
        XCTAssertGreaterThan(longText.contentSize.height, longText.bounds.height + 100)
        longText.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        longText.selectedRange = NSRange(location: 10, length: 3)
        await model.loadDetails()?.value; try await settle(host)
        XCTAssertEqual(longText.contentOffset.y, 100, accuracy: 1)
        XCTAssertEqual(longText.selectedRange, NSRange(location: 10, length: 3))
        for key in ["json", "empty", "binary"] {
            model.select(.init(name: key, kind: "key")); await model.loadDetails()?.value; try await settle(host)
            let text = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "redisStringText" })
            if key == "empty" { XCTAssertEqual(text.text, "") }
            if key == "binary" { XCTAssertEqual(text.text, "ff 00 fe") }
            if key == "json" {
                let picker = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UISegmentedControl }.first)
                picker.selectedSegmentIndex = 1; picker.sendActions(for: .valueChanged); try await settle(host)
                let jsonText = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.accessibilityIdentifier == "redisStringText" })
                XCTAssertTrue(jsonText.text.contains("\n")); XCTAssertTrue(jsonText.text.contains("9007199254740993"))
                XCTAssertTrue(jsonText.text.contains("1.00"))
            }
            try capture(window, key)
        }
    }
    private func settle(_ host: UIViewController) async throws {
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ window: UIWindow, _ name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try image.pngData()?.write(to: directory.appending(path: "redis-type-" + name + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
    }
}

private actor RedisTypePresentationService: MobileResourceServicing {
    private var longRevision = 0
    private var holds = false
    private var continuation: CheckedContinuation<Bool, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func holdNext() { holds = true }
    func waitUntilHeld() async { if continuation != nil { return }; await withCheckedContinuation { waiter = $0 } }
    func release(fail: Bool) { continuation?.resume(returning: fail); continuation = nil }
    func scopes() async throws -> [String] { ["0", "1"] }
    func catalog(scope: String, cursor: UInt64, search: String) async throws -> MobileResourceCatalog {
        .init(resources: ["group:member", "string", "json", "empty", "binary", "hash", "list", "set", "zset", "stream"].map { .init(name: $0, kind: "key") })
    }
    func details(resource: MobileResource, scope: String, offset: Int, cursor: UInt64) async throws -> MobileResourceDetails {
        if holds {
            holds = false
            let fail = await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
            if fail { throw URLError(.networkConnectionLost) }
        }
        let data: MobileGridData
        var chunk: RedisStringChunk?
        let type: RedisKeyType
        switch resource.name {
        case "hash": type = .hash; data = .init(columns: ["字段", "值"], rows: [["name", "你好 Redis"]])
        case "list": type = .list; data = .init(columns: ["索引", "值"], rows: [["0", "你好 Redis"]])
        case "set": type = .set; data = .init(columns: ["成员"], rows: [["你好 Redis"]])
        case "zset": type = .sortedSet; data = .init(columns: ["成员", "分数"], rows: [["你好 Redis", "1.5"]])
        case "stream": type = .stream; data = .init(columns: ["entryID", "fields"], rows: [["1-0", "message: 你好 Redis"]])
        default:
            type = .string
            longRevision += 1
            let bytes = resource.name == "binary" ? Data([255, 0, 254]) : Data((resource.name == "empty" ? "" : resource.name == "long" ? String(repeating: "long value\n", count: 500) + String(longRevision) : resource.name == "json" ? "{\"id\":9007199254740993,\"ratio\":1.00,\"name\":\"你好\"}" : "你好 Redis\n第二行，不需要位置列。").utf8)
            chunk = .init(value: .init(data: bytes), offset: 0, totalByteCount: bytes.count)
            data = .init(columns: ["值"], rows: [[String(data: bytes, encoding: .utf8) ?? "HEX: ff 00 fe"]])
        }
        return .init(data: data, structure: .init(columns: ["属性", "值"], rows: [["类型", type.rawValue]]), status: type.rawValue + " · 类型展示", redisType: type, redisString: chunk)
    }
}
