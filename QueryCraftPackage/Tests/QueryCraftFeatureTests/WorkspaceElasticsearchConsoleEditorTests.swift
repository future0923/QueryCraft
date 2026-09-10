import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct WorkspaceElasticsearchConsoleEditorTests {
    @Test func endpointCompletionsShowOnlyRemainingPathAndApplyWithoutDuplication() async throws {
        for (source, label, expected) in [
            ("GET /_cluster/h", "health", "GET /_cluster/health"),
            ("POST /日志/_validate/q", "query", "POST /日志/_validate/query"),
            ("GET /logs/_s", "_search", "GET /logs/_search"),
        ] {
            let mounted = mount(source)
            defer { mounted.window.close() }
            for _ in 0..<8 { await settle(mounted.host) }
            let controller = try controller(in: mounted.host)
            let service = WorkspaceElasticsearchCompletionService(fields: { _ in [] })
            let cursor = CursorPosition(range: NSRange(location: (source as NSString).length, length: 0))
            controller.textView.selectionManager.setSelectedRange(cursor.range)
            let response = try #require(await service.completionSuggestionsRequested(textView: controller, cursorPosition: cursor))
            let item = try #require(response.items.first { $0.label == label })
            service.completionWindowApplyCompletion(item: item, textView: controller, cursorPosition: cursor)
            #expect(controller.textView.string == expected)
            controller.textView.undoManager?.undo()
            #expect(controller.textView.string == source)
        }
    }

    @Test func resourceScopedMsearchKeepsSnippetSelectionAfterPrefixTrimming() async throws {
        let source = "POST /日志/_m"
        let mounted = mount(source)
        defer { mounted.window.close() }
        for _ in 0..<8 { await settle(mounted.host) }
        let controller = try controller(in: mounted.host)
        let service = WorkspaceElasticsearchCompletionService(fields: { _ in [] })
        let cursor = CursorPosition(range: NSRange(location: (source as NSString).length, length: 0))
        controller.textView.selectionManager.setSelectedRange(cursor.range)
        let response = try #require(await service.completionSuggestionsRequested(textView: controller, cursorPosition: cursor))
        let item = try #require(response.items.first { $0.label == "_msearch" })
        service.completionWindowApplyCompletion(item: item, textView: controller, cursorPosition: cursor)
        #expect(controller.textView.string.hasPrefix("POST /日志/_msearch\n{}\n"))
        #expect((controller.textView.string as NSString).substring(with: controller.textView.selectedRange()) == "match_all")
    }

    @Test func errorNavigationSelectsAndFocusesTheExistingEditor() async throws {
        let source = "GET /_cluster/health\nPOST /logs/_search\n{\"bad\":{}}"
        let mounted = mount(source)
        defer { mounted.window.close() }
        for _ in 0..<8 { await settle(mounted.host) }
        let controller = try controller(in: mounted.host)
        let navigation = WorkspaceElasticsearchEditorNavigationCoordinator()
        navigation.prepareCoordinator(controller: controller)
        let range = (source as NSString).range(of: "bad")
        navigation.navigate(to: range)
        #expect(controller.textView.selectedRange() == range)
        #expect(mounted.window.firstResponder === controller.textView)
        #expect(controller.textView.string == source)
    }

    private func mount(_ source: String) -> (window: NSWindow, host: NSView) {
        let host = NSHostingView(rootView: WorkspaceCodeEditElasticsearchEditor(text: .constant(source),
            selectedRange: .constant(NSRange(location: (source as NSString).length, length: 0)),
            completionFields: { _ in [] }, completionResources: { [] }))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (window, host)
    }

    private func controller(in host: NSView) throws -> TextViewController {
        let text = try #require(descendants(host).compactMap { $0 as? TextView }.first)
        var responder: NSResponder? = text
        while responder != nil && !(responder is TextViewController) { responder = responder?.nextResponder }
        return try #require(responder as? TextViewController)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func settle(_ view: NSView) async {
        await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        view.layoutSubtreeIfNeeded()
    }
}
