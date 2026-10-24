import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileElasticsearchPresentationTests: XCTestCase {
    func testNativeWorkspaceConsoleAndManagementSheets() async throws {
        guard let port = MobileElasticsearchTests.port else { throw XCTSkip("Requires disposable ES fixture") }
        let model = MobileElasticsearchWorkspace(profile: MobileElasticsearchTests.profile(port: port), password: nil)
        let service = try await model.ready(), name = "qc-es-ui-" + UUID().uuidString.lowercased()
        let create = try await service.executeRequest(.init(method: .put, path: "/" + name, body: Data(#"{"settings":{"number_of_replicas":0},"mappings":{"properties":{"name":{"type":"keyword"},"count":{"type":"long"}}}}"#.utf8)), policy: .writesAllowed)
        XCTAssertEqual(create.statusCode, 200)
        let prepared = try await service.prepareDocumentCreation(.init(targetName: name, targetKind: .index, id: "native", sourceJSON: Data(#"{"name":"原生文档 雪","count":9007199254740993}"#.utf8)))
        let created = try await service.commitDocumentCreation(prepared)
        await model.loadCatalog()?.value
        let object = try XCTUnwrap(model.catalog?.first { $0.name == name }); model.select(object); await model.loadPage(offset: 0, fresh: true)?.value
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey(); model.cancel() }
        func show<V: View>(_ view: V, name: String, dark: Bool = false) async throws {
            let host = UIHostingController(rootView: view); window.rootViewController = host; window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.makeKeyAndVisible(); host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(220)); host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.width, 300); XCTAssertGreaterThan(host.view.bounds.height, 300)
            if let directory = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                let url = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
                try image.pngData()?.write(to: url.appending(path: "es-\(name)-\(device).png"))
            }
        }
        let app = MobileApplicationModel(repository: ESUIRepository())
        try await show(MobileElasticsearchWorkspaceView(app: app, model: model), name: "workspace", dark: true)
        for kind in [MobileElasticsearchAction.Kind.document, .createDocument, .mapping, .settings, .aliases, .templates, .simulate, .createIndex, .deleteIndex, .batchDelete] {
            let action = MobileElasticsearchAction(owner: model, kind: kind, object: object, reference: kind == .document ? created.reference : nil)
            await action.reload()?.value
            XCTAssertTrue(action.hasLoaded, action.message ?? "load")
            try await show(MobileElasticsearchActionView(action: action), name: kind.rawValue, dark: kind == .mapping || kind == .aliases)
            if kind == .createDocument {
                action.documentID = "phone-new"; action.source = #"{"name":"完整确认内容","count":2}"#; await action.prepare()?.value
                XCTAssertTrue(action.preview?.contains("完整确认内容") == true)
                try await show(MobileElasticsearchActionView(action: action), name: "confirmation")
            }
        }
        model.console.source = "GET /\(name)/_search\n{\"query\":{\"match_all\":{}}}"; await model.console.prepare()?.value; await model.console.run()?.value
        try await show(NavigationStack { MobileElasticsearchConsoleView(console: model.console) }, name: "console")
        // Mount single and multiple result variants in the same native viewport.
        window.rootViewController = UIHostingController(rootView: Color.clear)
        model.console.scope = "all"
        model.console.source = "GET /\(name)/_search\n{\"query\":{\"match_all\":{}}}\n\nGET /\(name)/_count"
        await model.console.prepare()?.value; await model.console.run()?.value; model.console.selectedResult = 0
        XCTAssertEqual(model.console.results.count, 2)
        try await show(NavigationStack { MobileElasticsearchConsoleView(console: model.console) }, name: "console-batch")
        try await show(MobileElasticsearchFilterView(model: model), name: "filter", dark: true)
        let snapshot = try await service.fetchDocument(created.reference, maximumByteCount: 1_048_576)
        try model.cellChanges.stage(snapshot: snapshot, edits: ["name": .text("全屏待提交")]) { draft in try await service.prepareDocumentPartialUpdate(draft) }
        await model.cellChanges.waitForValidation(); model.didStage()
        let fullscreen = MobileFullscreenGridSelection(data: model.data, revision: model.revision.uuidString, widthKey: name, viewport: model.viewport, elasticsearch: model)
        try await show(MobileFullscreenGrid(selection: fullscreen), name: "fullscreen", dark: true)
        model.beginFullscreenChanges(); await model.fullscreenAction?.reload()?.value
        XCTAssertEqual(model.fullscreenAction?.kind, .cellChanges)
        try await Task.sleep(for: .milliseconds(220))
        model.fullscreenAction?.close(); model.cellChanges.discard()
        _ = try await service.executeRequest(.init(method: .delete, path: "/" + name), policy: .writesAllowed); await service.close()
    }
}
@MainActor private final class ESUIRepository: MobileLibraryPersisting {
    func load() throws -> MobileLibraryState { .init() }
    func write(_ state: MobileLibraryState) throws {}
}
