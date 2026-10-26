import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileCanvasPresentationTests: XCTestCase {
    func testActualSplitSidebarUsesOpaqueBlackAcrossSQLRedisAndES() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.interfaceOrientation
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; previous?.makeKey()
            if UIDevice.current.userInterfaceIdiom == .phone {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: original.isLandscape ? .landscape : .portrait))
            }
        }
        let app = MobileApplicationModel(repository: CanvasLibrary())
        let profile = MobileConnectionProfile(id: UUID(), name: "Canvas", host: "unused", port: 6379, username: "", database: "0", tlsMode: .disabled, remembersPassword: false, requiresPassword: false, driver: .redis)
        let model = MobileResourceModel(profile: profile, password: nil)
        let browser = MobileBrowserModel(configuration: .init(host: "unused", port: 1, username: "unused", password: nil, database: "db", tlsMode: .disabled))
        var esProfile = profile; esProfile.driver = .elasticsearch
        let es = MobileElasticsearchWorkspace(profile: esProfile, password: nil)
        let pages: [(String, AnyView)] = [
            ("redis", AnyView(MobileResourceWorkspaceView(app: app, model: model))),
            ("sql", AnyView(NavigationSplitView { MobileCatalogView(app: app, browser: browser, kind: .table) } detail: { Color.black })),
            ("elasticsearch", AnyView(MobileElasticsearchWorkspaceView(app: app, model: es)))
        ]
        for (name, page) in pages {
            let host = UIHostingController(rootView: page.mobileAppearance())
            window.rootViewController = host; window.makeKeyAndVisible()
            if UIDevice.current.userInterfaceIdiom == .phone {
                host.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while window.bounds.width <= window.bounds.height, UIDevice.current.userInterfaceIdiom == .phone, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            let split = try XCTUnwrap(controller(UISplitViewController.self, host))
            XCTAssertFalse(split.isCollapsed, "Must validate an actual expanded split, not an isolated page")
            let sidebar = try XCTUnwrap(split.viewControllers.first)
            for style in [UIUserInterfaceStyle.dark, .light, .dark] {
                window.overrideUserInterfaceStyle = style
                try await Task.sleep(for: .milliseconds(250)); host.view.layoutIfNeeded()
                let frame = sidebar.view.convert(sidebar.view.bounds, to: window)
                let format = UIGraphicsImageRendererFormat(); format.preferredRange = .standard
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let data = try XCTUnwrap(image.cgImage?.dataProvider?.data)
                let bytes = try XCTUnwrap(CFDataGetBytePtr(data)), cg = try XCTUnwrap(image.cgImage)
                let point = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.58)
                let x = min(cg.width - 1, max(0, Int(point.x * image.scale)))
                let y = min(cg.height - 1, max(0, Int(point.y * image.scale)))
                let offset = y * cg.bytesPerRow + x * cg.bitsPerPixel / 8
                let expected = style == .dark ? 0 : 255
                for channel in 0..<3 { XCTAssertEqual(Int(bytes[offset + channel]), expected, "\(name) sidebar must be true black/white at \(point)") }
                let attachment = XCTAttachment(image: image); attachment.name = "split-canvas-\(name)-\(style.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    private func controller<T: UIViewController>(_ type: T.Type, _ root: UIViewController) -> T? {
        if let result = root as? T { return result }
        return root.children.lazy.compactMap { self.controller(type, $0) }.first
    }
}

@MainActor private struct CanvasLibrary: MobileLibraryPersisting {
    func load() throws -> MobileLibraryState { .init() }
    func write(_ state: MobileLibraryState) throws {}
}
