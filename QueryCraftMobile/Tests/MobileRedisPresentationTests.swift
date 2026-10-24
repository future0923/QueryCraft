import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileRedisPresentationTests: XCTestCase {
    func testRealResourceEntryPresentsEditorAndKeepsContentDuringRefresh() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis fixture") }
        let profile = try MobileRedisMutationTests.profile()
        let key = "querycraft:mobile-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect(); _ = try await client.execute(["SET", key, "你好 Redis"])
        do {
            let app = MobileApplicationModel(), model = MobileResourceModel(profile: profile, password: nil)
            await model.load()?.value; model.select(.init(name: key, kind: "键")); await model.loadDetails()?.value
            let host = UIHostingController(rootView: MobileResourceWorkspaceView(app: app, model: model))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey(); model.cancel() }
            try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
            let grid = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first { $0.delegate is MobileDataGrid.Coordinator })
            let frame = grid.frame
            model.beginRedisEditing()
            let editor = try XCTUnwrap(model.redisEditor); await editor.reload()?.value
            try await Task.sleep(for: .milliseconds(500)); host.view.layoutIfNeeded()
            let sheet = try XCTUnwrap(host.presentedViewController)
            XCTAssertTrue(descendants(sheet.view).contains { ($0 as? UITextView)?.text == "你好 Redis" })
            XCTAssertTrue(editor.safetyLock.isEnabled)
            editor.safetyLock.disable(); editor.text = "从 iOS 编辑 Redis"; editor.expirationMode = .expires; editor.ttl = "60000"
            editor.prepare(); XCTAssertTrue(editor.preview?.contains("KEEPTTL") == true)
            XCTAssertTrue(editor.preview?.contains("PEXPIRE") == true)
            try await Task.sleep(for: .milliseconds(180)); sheet.view.layoutIfNeeded()
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: directory.appending(path: "redis-edit-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            await editor.submit()?.value; XCTAssertFalse(editor.hasChanges); XCTAssertFalse(editor.needsVerification)
            model.closeRedisEditor()
            try await Task.sleep(for: .milliseconds(400)); host.view.layoutIfNeeded()
            XCTAssertEqual(grid.frame, frame)
            let stored = try await client.execute(["GET", key]).stringValue
            XCTAssertEqual(stored, "从 iOS 编辑 Redis")
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    func testCreationAndRenameSheetsUseResourceEntryAndRefreshFilteredCatalog() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis fixture") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:mobile-key-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        do {
            let app = MobileApplicationModel(), model = MobileResourceModel(profile: profile, password: nil)
            await model.load()?.value; model.redisSearchMode = .exact; model.search = key; await model.loadCatalog()?.value
            let host = UIHostingController(rootView: MobileResourceWorkspaceView(app: app, model: model))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey(); model.cancel() }
            try await Task.sleep(for: .milliseconds(200))
            model.beginRedisKeyCreation(.hash)
            let action = try XCTUnwrap(model.redisKeyAction)
            XCTAssertTrue(model.hasPendingChanges); model.selectScope("1"); XCTAssertEqual(model.scope, "0")
            action.name = key; action.addRow(); action.rows[0].firstValue = "name"; action.rows[0].secondValue = "新建 Hash"
            action.safetyLock.disable()
            try await Task.sleep(for: .milliseconds(400)); host.view.layoutIfNeeded()
            action.prepare()
            try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
            let sheet = try XCTUnwrap(host.presentedViewController)
            XCTAssertGreaterThan(sheet.view.bounds.height, 0)
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: directory.appending(path: "redis-create-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            await action.submit()?.value; XCTAssertTrue(action.succeeded); model.closeRedisKeyAction()
            await model.loadCatalog()?.value; await model.loadDetails()?.value
            XCTAssertEqual(model.selected?.name, key); XCTAssertTrue(model.catalog?.contains { $0.name == key } == true)
            try await Task.sleep(for: .milliseconds(400))
            model.beginRedisKeyRename(try XCTUnwrap(model.selected))
            let rename = try XCTUnwrap(model.redisKeyAction)
            rename.name = key + ":new"; rename.safetyLock.disable(); rename.prepare(); await rename.submit()?.value
            XCTAssertTrue(rename.succeeded); model.closeRedisKeyAction()
            await model.loadCatalog()?.value; await model.loadDetails()?.value
            XCTAssertEqual(model.selected?.name, key + ":new")
            XCTAssertEqual(model.catalog?.count, 0) // Exact MATCH must not acquire the renamed destination.
            XCTAssertFalse(model.hasPendingChanges)
            let stored = try await client.execute(["HGET", key + ":new", "name"]).stringValue
            XCTAssertEqual(stored, "新建 Hash")
            _ = try await client.execute(["DEL", key, key + ":new"]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key, key + ":new"]); await client.close(); throw error }
    }
    func testHashFieldExpirationControlsFollowServerCapability() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:ttl-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect(); _ = try await client.execute(["HSET", key, "field", "value"])
        do {
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value
            let host = UIHostingController(rootView: MobileRedisEditorView(editor: editor, close: {}))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            let fields = descendants(host.view).compactMap { $0 as? UITextField }
            XCTAssertEqual(fields.contains { $0.placeholder?.contains("字段 TTL") == true }, editor.snapshot?.hashFieldExpirationSupport == true)
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: directory.appending(path: "redis-field-ttl-" + (ProcessInfo.processInfo.environment["PROOF_REDIS_FIELD_TTL"] == "1" ? "74-" : "72-") + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    func testLargeListEditorMountsAbsoluteIndexOnSecondPage() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:page-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect(); _ = try await client.execute(["RPUSH", key] + (0..<1200).map(String.init))
        do {
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value
            let host = UIHostingController(rootView: MobileRedisEditorView(editor: editor, close: {}))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
            let bounds = host.view.bounds
            await editor.nextPage()?.value
            try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
            XCTAssertEqual(editor.rows.first?.originalIndex, 200); XCTAssertEqual(host.view.bounds, bounds)
            XCTAssertTrue(descendants(host.view).contains { ($0 as? UITextField)?.text == "200" || ($0 as? UITextView)?.text == "200" })
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "redis-paging-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    func testMemberSearchUsesSharedStateAndKeepsContainerStable() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:search-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect(); _ = try await client.execute(["RPUSH", key] + (0..<1199).map(String.init) + ["find-last"])
        do {
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value; editor.searchState.present()
            let host = UIHostingController(rootView: MobileRedisEditorView(editor: editor, close: {}))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey() }
            try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded(); let bounds = host.view.bounds
            editor.searchState.draftText = "find-last"; await editor.applySearch()?.value
            try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
            XCTAssertEqual(editor.rows.first?.originalIndex, 1199); XCTAssertEqual(editor.snapshot?.matchingCount, 1)
            XCTAssertEqual(host.view.bounds, bounds)
            XCTAssertTrue(descendants(host.view).compactMap { $0 as? UITextField }.contains { $0.text == "find-last" })
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "redis-search-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    func testResourceConsoleEntryAndLargeStringNativeEditor() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:complete-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect()
        let value = String(repeating: "large value\n", count: 100_000)
        _ = try await client.execute(["SET", key, value])
        do {
            let model = MobileResourceModel(profile: profile, password: nil)
            await model.load()?.value; model.beginRedisConsole()
            let console = try XCTUnwrap(model.redisConsole)
            XCTAssertTrue(model.hasPendingChanges); model.selectScope("1"); XCTAssertEqual(model.scope, "0")
            let host = UIHostingController(rootView: MobileRedisConsoleView(console: console, document: console.document, close: {}))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.overrideUserInterfaceStyle = .light; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey(); model.cancel() }
            try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
            console.document.updateSource("PING"); await console.run()?.value
            guard case .success(let reply, _) = console.document.transcriptEntries.last?.outcome else { XCTFail("Missing console reply"); return }
            XCTAssertEqual(reply, .simpleString("PONG"))
            XCTAssertTrue(descendants(host.view).contains { $0 is UITextView })
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "redis-console-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            await console.close()
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value; XCTAssertEqual(editor.text.utf8.count, value.utf8.count)
            let largeHost = UIHostingController(rootView: MobileRedisEditorView(editor: editor, close: {}))
            window.rootViewController = largeHost
            try await Task.sleep(for: .milliseconds(350)); largeHost.view.layoutIfNeeded()
            XCTAssertTrue(editor.usesStringSegments)
            XCTAssertTrue(descendants(largeHost.view).compactMap { $0 as? UITextView }.contains { $0.text.contains("large value") && $0.text.utf8.count <= 32_772 })
            editor.safetyLock.disable(); editor.text += "edited"; await editor.prepare()?.value; XCTAssertNotNil(editor.preview)
            await editor.submit()?.value; XCTAssertFalse(editor.needsVerification)
            let actual = try await client.execute(["STRLEN", key]).integerValue
            XCTAssertEqual(actual, Int64(value.utf8.count + 6))
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    func testGroupedCatalogAndMetadataActionsAtCompactAndWideSizes() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires isolated Redis") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:metadata-ui:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect(); _ = try await client.execute(["XADD", key, "*", "message", "stream entry"])
        do {
            let model = MobileResourceModel(profile: profile, password: nil)
            await model.load()?.value; model.search = key; await model.loadCatalog()?.value
            XCTAssertNotNil(model.redisTree); XCTAssertEqual(model.catalog?.count, 1)
            let host = UIHostingController(rootView: MobileResourceWorkspaceView(app: MobileApplicationModel(), model: model))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
            defer { window.isHidden = true; previous?.makeKey(); model.cancel() }
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            func capture(_ name: String) throws {
                if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "redis-" + name + "-" + device + ".png"))
                }
            }
            try capture("catalog-dark")
            let resource = try XCTUnwrap(model.catalog?.first)
            model.select(resource); await model.loadDetails()?.value
            XCTAssertEqual(model.details?.redisType, .stream); XCTAssertFalse(model.canEditRedis)
            model.beginRedisMetadataAction(resource, action: .expiration)
            let action = try XCTUnwrap(model.redisKeyAction); await action.loadMetadata()?.value
            try await Task.sleep(for: .milliseconds(500)); host.view.layoutIfNeeded()
            let sheet = try XCTUnwrap(host.presentedViewController)
            XCTAssertTrue(descendants(sheet.view).compactMap { $0 as? UITextField }.contains { $0.placeholder?.contains("TTL") == true })
            action.safetyLock.disable(); action.expirationMode = .expires; action.ttl = "60000"; action.prepare()
            XCTAssertTrue(action.preview?.contains("PEXPIRE") == true)
            try await Task.sleep(for: .milliseconds(200)); try capture("metadata-dark")
            await action.submit()?.value; XCTAssertTrue(action.succeeded); model.closeRedisKeyAction()
            await model.loadDetails()?.value
            let ttl = try await client.execute(["PTTL", key]).integerValue
            XCTAssertGreaterThan(ttl ?? 0, 0)
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
