import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileSQLSnippetPresentationTests: XCTestCase {
    func testActualRepresentableExpandsTemplateAndTouchControlsTrackSharedSession() async throws {
        let draft = SnippetRenderDraft(), controls = MobileSQLSnippetContext()
        let host = UIHostingController(rootView: SnippetRenderView(draft: draft, controls: controls).mobileAppearance())
        let (window, previous) = try mount(host)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        let view = try await editor(in: host.view)
        view.becomeFirstResponder()
        try await wait { view.hasCompletions }
        XCTAssertTrue(view.acceptCompletion?() == true)
        try await wait { controls.isActive }
        XCTAssertEqual(draft.text, SQLSnippetTemplate(content: try XCTUnwrap(SQLSnippetStore.defaultSnippets.first { $0.trigger == "cte" }).content).insertionText)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "name")
        XCTAssertEqual(controls.count, 4)
        view.insertText("recent_users")
        try await wait { draft.text.contains("recent_users") }
        controls.move(1)
        XCTAssertEqual((view.text as NSString).substring(with: view.selectedRange), "columns")
        XCTAssertEqual(draft.selection, view.selectedRange)
        XCTAssertEqual(view.snippetHints.count, 2)
        for style in [UIUserInterfaceStyle.dark, .light] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
            capture(host, name: style == .dark ? "sql-snippet-navigation-dark" : "sql-snippet-navigation-light")
        }
        controls.end(); XCTAssertFalse(controls.isActive)
        XCTAssertTrue(view.snippetHints.isEmpty)
        XCTAssertTrue(view.isFirstResponder)
    }

    func testManagementAndMultilineTemplateEditorRenderExistingSharedStore() async throws {
        let suite = "SnippetPresentation.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SQLSnippetStore(userDefaults: defaults)
        let host = UIHostingController(rootView: MobileSQLSnippetsView(store: store).mobileAppearance())
        let (window, previous) = try mount(host)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
        capture(host, name: "sql-snippet-management")
        XCTAssertFalse(descendants(host.view).compactMap { $0 as? UICollectionView }.isEmpty)
        let snippet = try XCTUnwrap(store.snippets.first { $0.trigger == "cte" })
        let edit = UIHostingController(rootView: MobileSQLSnippetEditor(store: store, snippet: snippet).mobileAppearance())
        window.rootViewController = edit; edit.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        let fields = descendants(edit.view).compactMap { $0 as? UITextField }
        XCTAssertTrue(fields.contains { $0.text == snippet.name })
        XCTAssertTrue(fields.contains { $0.text == snippet.trigger && $0.autocorrectionType == .no })
        let content = try XCTUnwrap(descendants(edit.view).compactMap { $0 as? UITextView }.first { $0.text == snippet.content })
        XCTAssertTrue(content.text.contains("${columns}")); capture(edit, name: "sql-snippet-multiline-editor")
    }

    private func mount(_ host: UIViewController) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark; window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        return (window, previous)
    }
    private func editor(in view: UIView) async throws -> MobileSQLTextView {
        try await wait { self.descendants(view).contains { $0 is MobileSQLTextView } }
        return try XCTUnwrap(descendants(view).compactMap { $0 as? MobileSQLTextView }.first)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func capture(_ host: UIViewController, name: String) {
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor @Observable private final class SnippetRenderDraft {
    var text = "cte"
    var selection = NSRange(location: 3, length: 0)
    var focused = true
}
private struct SnippetRenderView: View {
    @Bindable var draft: SnippetRenderDraft
    let controls: MobileSQLSnippetContext
    @State private var schema = MobileSQLSchemaCatalog()
    var body: some View {
        VStack {
            HStack { Text("SQL"); Spacer(); MobileSQLSnippetControls(context: controls) }.padding()
            MobileSQLEditor(text: $draft.text, selection: $draft.selection, isFocused: $draft.focused,
                            schema: schema, defaultDatabase: "", snippets: SQLSnippetStore.defaultSnippets.map(SQLSnippetCompletionSource.init(snippet:)), snippetContext: controls) {}
                .frame(height: 240)
            Spacer()
        }.background(Color(uiColor: .systemBackground))
    }
}
