import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileRemainingPresentationTests: XCTestCase {
    func testNativeDocumentsEditorSettingsTransferAndConfirmation() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_TRANSFER_MYSQL_PORT"] != nil else { throw XCTSkip("Requires owned workspace fixtures") }
        let mysql = try MobileTransferIntegrationTests.connection(.mysql), pg = try MobileTransferIntegrationTests.connection(.postgresql)
        var source = MobileDriverSupportTests.profile(.mysql), target = MobileDriverSupportTests.profile(.postgresql)
        source.name = "迁移来源 MySQL"; source.username = "root"; source.port = mysql.configuration.port; source.database = mysql.endpoint.database
        target.name = "迁移目标 PostgreSQL"; target.username = "postgres"; target.port = pg.configuration.port; target.database = pg.endpoint.database; target.schemaName = pg.endpoint.schema
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DataTransferManager(historyURL: directory.appending(path: "history.json"))
        let model = MobileTransferModel(profiles: [source, target], manager: manager,
            library: DataTransferLibraryStore(url: directory.appending(path: "tasks.json")), resolve: { id, _ in id == source.id ? mysql.configuration : pg.configuration })
        model.chooseProfile(source.id, side: .source); await model.reload(.source)?.value
        model.chooseProfile(target.id, side: .target); await model.reload(.target)?.value
        let object = try XCTUnwrap(model.objects.first { $0.name == "sample" && $0.kind == .table })
        model.select(object, enabled: true)
        await model.prepare()?.value
        let plan = try XCTUnwrap(model.preview, model.message ?? "No preview")
        model.showingPreview = false
        let workspace = MobileDatabaseWorkspace(profile: source, password: mysql.configuration.password, service: MobileMySQLService(), workspaceRepository: MobileWorkspaceRepository(directory: directory.appending(path: "workspace")))
        workspace.query.sql = "SELECT id, value FROM sample ORDER BY id LIMIT 3"
        await workspace.query.executeAll()?.value
        let first = try XCTUnwrap(workspace.activeDocument)
        workspace.renameDocument(first.id, title: "完整查询结果")
        workspace.saveDocument(first.id)
        let second = try XCTUnwrap(workspace.newDocument())
        second.query.sql = "SELECT '保留草稿 😀' AS value;\nSELECT NULL AS missing;"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey(); workspace.cancelAll(); model.background(true) }
        try await show(MobileSQLDocumentsView(workspace: workspace), window: window, name: "documents")
        try await show(MobileWorkspaceView(model: second.query, widthKey: source.id.uuidString, documentWorkspace: workspace), window: window, name: "document-editor", dark: true)
        let suite = "MobileRemainingPresentation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MobileEditorPreferences(defaults: defaults)
        preferences.colors[.light].apply(.ocean); preferences.fontSize = 17
        try await show(MobileEditorSettingsView(preferences: preferences, connection: source.configuration(password: nil)), window: window, name: "editor-settings")
        try await show(MobileEditorSettingsView(preferences: preferences), window: window, name: "editor-settings-bottom", dark: true, bottom: true)
        try await show(MobileTransferView(model: model), window: window, name: "transfer")
        model.message = "连接读取失败，请检查服务器地址、权限和网络后重新读取。原有配置保留；只有读取成功后才更新对象目录。"
        try await show(MobileTransferView(model: model), window: window, name: "transfer-error")
        model.message = nil
        try await show(MobileTransferView(model: model), window: window, name: "transfer-bottom", bottom: true)
        try await show(MobileTransferPreview(model: model, plan: plan), window: window, name: "transfer-confirm", bottom: true)
        model.saveTask()
        try model.library.update { $0.folders.append(.init(name: "常用迁移", parentID: nil)) }
        try await show(MobileTransferTaskLibraryView(model: model, open: { _ in }), window: window, name: "transfer-tasks")
        XCTAssertEqual(workspace.documents.count, 2); XCTAssertEqual(workspace.query.sql, second.query.sql)
    }

    func testNativeFontPaletteIndentCompletionAndMarkedInput() async throws {
        let suite = "MobileEditorNative." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MobileEditorPreferences(defaults: defaults), model = MobileQueryModel()
        preferences.fontSize = 17; preferences.colors[.light].apply(.ocean); preferences.completionKey = .returnKey; preferences.indentationWidth = 2
        model.sql = "SELECT '雪😀';\nSELECT NULL;"
        let editor = MobileSQLEditor(text: Binding(get: { model.sql }, set: { model.sql = $0 }),
            selection: Binding(get: { model.executionInput.selection }, set: { model.executionInput.selection = $0 }), isFocused: .constant(false),
            schema: MobileSQLSchemaCatalog(), defaultDatabase: "", preferences: preferences) {}
        let coordinator = MobileSQLEditor.Coordinator(editor), view = MobileSQLEditor.makeTextView(coordinator: coordinator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.frame = scene.coordinateSpace.bounds
        view.frame = CGRect(x: 0, y: 80, width: window.bounds.width, height: 240); host.view.addSubview(view); window.makeKeyAndVisible()
        defer { coordinator.stop(); window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        coordinator.update(view, mode: .light)
        let deadline = ContinuousClock.now + .seconds(3)
        while EditorHexColor.hex(view.backgroundColor ?? .clear) != preferences.colors[.light].hex(for: .background, mode: .light), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(view.font?.pointSize, 17)
        XCTAssertEqual(EditorHexColor.hex(view.backgroundColor ?? .clear), preferences.colors[.light].hex(for: .background, mode: .light))
        coordinator.update(view, mode: .dark)
        XCTAssertEqual(EditorHexColor.hex(view.backgroundColor ?? .clear), preferences.colors[.dark].hex(for: .background, mode: .dark))
        XCTAssertEqual(view.decorations.mode, .dark)
        coordinator.update(view, mode: .light)
        view.layoutIfNeeded(); view.decorations.update(view)
        let lineNumbers = view.subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden && $0.accessibilityIdentifier == "sqlLineNumber" }.compactMap(\.text)
        XCTAssertEqual(Set(lineNumbers), Set(["1", "2"]))
        let emojiRange = (view.text as NSString).range(of: "😀")
        if let fallback = UIFont(name: "AppleColorEmoji", size: 17) {
            let actual = view.textStorage.attribute(.font, at: emojiRange.location, effectiveRange: nil) as? UIFont
            XCTAssertEqual(actual?.fontName, fallback.fontName)
        }
        if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
            let comparison = UILabel(frame: CGRect(x: 24, y: 360, width: 240, height: 60))
            comparison.text = "System emoji: 😀"; comparison.font = .systemFont(ofSize: 24)
            host.view.addSubview(comparison)
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "workspace-editor-glyphs-\(device).png"))
            comparison.removeFromSuperview()
        }
        var accepted = 0; view.acceptCompletion = { accepted += 1; return true }
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        view.perform(NSSelectorFromString("tab"))
        XCTAssertEqual(accepted, 0); XCTAssertTrue(view.text.hasSuffix("  "))
        preferences.completionKey = .tab; coordinator.update(view, mode: .light)
        view.perform(NSSelectorFromString("tab")); XCTAssertEqual(accepted, 1)
        view.becomeFirstResponder(); view.setMarkedText("中文输入", selectedRange: NSRange(location: 2, length: 0)); coordinator.textViewDidChange(view)
        XCTAssertNotNil(view.markedTextRange)
        preferences.fontSize = 18; preferences.colors[.light].apply(.soft)
        coordinator.update(view, mode: .light)
        XCTAssertNotNil(view.markedTextRange); XCTAssertTrue(view.text.contains("中文输入"))
        view.unmarkText(); coordinator.textViewDidChange(view)
    }

    private func show<V: View>(_ view: V, window: UIWindow, name: String, dark: Bool = false, bottom: Bool = false) async throws {
        let host = UIHostingController(rootView: view)
        window.rootViewController = host; window.overrideUserInterfaceStyle = dark ? .dark : .light
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(name == "document-editor" ? 700 : 180)); host.view.layoutIfNeeded()
        if bottom {
            func scroll(_ view: UIView) {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                }
                view.subviews.forEach(scroll)
            }
            scroll(host.view); try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded(); scroll(host.view)
            try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded(); scroll(host.view)
            try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        }
        XCTAssertGreaterThan(host.view.bounds.height, 200)
        if name == "document-editor" {
            func checkEditor(_ root: UIView) {
                if let editor = root as? MobileSQLTextView {
                    let labels = editor.subviews.compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier == "sqlLineNumber" }
                    let caret = editor.caretRect(for: editor.beginningOfDocument)
                    if caret.intersects(editor.bounds) {
                        XCTAssertTrue(labels.contains { $0.text == "1" && !$0.isHidden && $0.frame.intersects(editor.bounds) }, "Visible first source line must have a visible gutter number")
                    }
                    if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                        let data: [String: Any] = ["bounds": String(describing: editor.bounds), "caret": String(describing: caret), "labels": labels.map { ["text": $0.text ?? "", "hidden": String($0.isHidden), "frame": String(describing: $0.frame)] }]
                        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
                        try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: output).appending(path: "workspace-editor-layout-\(device).json"))
                    }
                }
                root.subviews.forEach(checkEditor)
            }
            checkEditor(host.view)
        }
        if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try image.pngData()?.write(to: directory.appending(path: "workspace-\(name)-\(device).png"))
        }
    }
}
