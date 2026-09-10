import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct WorkspaceElasticsearchConsoleResultViewTests {
    @Test func aggregationResultOpensCompleteJSONInStableLightAndDarkViewports() async throws {
        let source = "POST /test/_search\n{\"size\":0}"
        let parsed = try #require(ElasticsearchConsoleParser().parse(source).first)
        let response = WorkspaceRequestExecutionResult(statusCode: 200, contentType: "application/json",
            body: Data(#"{"took":2,"_shards":{"total":1,"successful":1,"failed":0},"hits":{"total":{"value":3,"relation":"eq"},"hits":[]},"aggregations":{"cities":{"buckets":[{"key":"沈阳","doc_count":2},{"key":"长春","doc_count":1}]}}}"#.utf8))
        let analyzed = try await WorkspaceElasticsearchResponseConversionWorker().analyze(
            from: response, maximumRows: 10, parsed: parsed, source: source)
        let result = WorkspaceElasticsearchConsoleResult(request: parsed.request, statusCode: 200,
            output: analyzed.output, errorMessage: nil, elapsedSeconds: 0.01, details: analyzed.details)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: WorkspaceElasticsearchConsoleResultView(result: result)
                .environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 400),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            for _ in 0..<30 { await settle(host) }
            let text = try #require(descendants(host).compactMap { $0 as? TextView }.first)
            #expect(!text.isEditable)
            #expect(text.string.contains("aggregations") && text.string.contains("沈阳"))
            var responder: NSResponder? = text
            while responder != nil && !(responder is TextViewController) { responder = responder?.nextResponder }
            let controller = try #require(responder as? TextViewController)
            for size in [CGSize(width: 600, height: 320), CGSize(width: 850, height: 500)] {
                window.setContentSize(size)
                for _ in 0..<8 { await settle(host) }
                #expect(host.frame.size == size)
                #expect(controller.view.clipsToBounds)
                #expect(controller.view.bounds.height > 100)
                #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(controller.view.convert(controller.view.bounds, to: host)))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func settle(_ view: NSView) async {
        await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        view.layoutSubtreeIfNeeded()
    }
}
