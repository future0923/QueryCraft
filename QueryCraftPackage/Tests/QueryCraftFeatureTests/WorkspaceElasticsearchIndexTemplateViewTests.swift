import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

@Suite(.serialized) @MainActor
struct WorkspaceElasticsearchIndexTemplateViewTests {
    @Test func nativeManagerKeepsAcceptedGeometryInBothAppearances() async {
        let model = WorkspaceModel(
            profileID: UUID(),
            repository: InMemoryConnectionProfileRepository(profiles: []),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["Elasticsearch"])
        )
        for (appearance, scheme) in [
            (NSAppearance.Name.aqua, ColorScheme.light),
            (.darkAqua, .dark),
        ] {
            let view = NSHostingView(rootView: WorkspaceElasticsearchIndexTemplateManagerSheet(
                model: model,
                dismiss: {}
            ).environment(\.colorScheme, scheme))
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            await settle(view)
            #expect(view.frame.size == CGSize(width: 920, height: 640))
            #expect(view.fittingSize.width >= 780)
            #expect(view.fittingSize.height >= 540)
            #expect(descendants(of: view).contains {
                $0.accessibilityIdentifier() == "elasticsearchIndexTemplateSearch"
            })
            window.close()
        }
    }

    @Test func presentingManagerAsASheetKeepsTheKeyViewLoopResponsive() async {
        let model = WorkspaceModel(
            profileID: UUID(),
            repository: InMemoryConnectionProfileRepository(profiles: []),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["Elasticsearch"])
        )
        let view = NSHostingView(rootView: TemplateManagerSheetHarness(model: model))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<12 { await settle(view) }
        #expect(window.attachedSheet != nil)
        #expect(window.attachedSheet?.isVisible == true)
        window.close()
    }

    private func settle(_ view: NSView) async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        view.layoutSubtreeIfNeeded()
    }

    @Test func simulationPaneKeepsReadOnlyJSONInsideBothAppearanceViewports() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: WorkspaceElasticsearchTemplateSimulationView(execute: { _ in
                Issue.record("The initial preview pane must not send requests.")
                return .init(statusCode: 200, contentType: "application/json", body: Data("{}".utf8))
            }).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 650, height: 580),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            for _ in 0..<12 { await settle(host) }
            let resultEditor = try #require(descendants(of: host).compactMap { $0 as? TextView }.first)
            #expect(!resultEditor.isEditable && resultEditor.string == "{}")
            var responder: NSResponder? = resultEditor
            while responder != nil && !(responder is TextViewController) { responder = responder?.nextResponder }
            let controller = try #require(responder as? TextViewController)
            for size in [CGSize(width: 500, height: 480), CGSize(width: 650, height: 580)] {
                window.setContentSize(size)
                for _ in 0..<8 { await settle(host) }
                #expect(host.frame.size == size)
                #expect(controller.view.clipsToBounds)
                #expect(controller.view.bounds.height > 100)
                let viewport = controller.view.convert(controller.view.bounds, to: host)
                #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(viewport))
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    Attachment.record(data, named: "template-simulation-\(scheme == .dark ? "dark" : "light").png")
                }
            }
        }
    }

    @Test func longTemplateStaysInsideItsViewportWhileEditingAndResizing() async throws {
        let model = WorkspaceModel(
            profileID: UUID(),
            repository: InMemoryConnectionProfileRepository(profiles: []),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["Elasticsearch"])
        )
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: TemplateManagerSheetHarness(model: model)
                .environment(\.colorScheme, scheme))
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
                window.close()
            }
            for _ in 0..<12 { await settle(host) }
            let sheet = try #require(window.attachedSheet)
            let content = try #require(sheet.contentView)
            let add = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first {
                $0.toolTip == AppCopy.current.text("新建索引模板", "New Index Template")
            })
            add.performClick(nil)
            for _ in 0..<12 { await settle(content) }
            let textView = try #require(descendants(of: content).compactMap { $0 as? TextView }.first)
            var responder: NSResponder? = textView
            while responder != nil && !(responder is TextViewController) { responder = responder?.nextResponder }
            let controller = try #require(responder as? TextViewController)
            let source = "{\n  \"index_patterns\": [\"viewport-*\"],\n  \"_meta\": {\n"
                + (0..<80).map { "    \"field\($0)\": \"value\"" }.joined(separator: ",\n")
                + "\n  },\n  \"version\": 2\n}"
            sheet.makeFirstResponder(textView)
            textView.selectAll(nil)
            textView.insertText(source)
            for size in [CGSize(width: 780, height: 540), CGSize(width: 920, height: 640)] {
                sheet.setContentSize(size)
                for _ in 0..<8 { await settle(content) }
                #expect(controller.view.clipsToBounds)
                let viewport = controller.view.convert(controller.view.bounds, to: content)
                for offset in [CGFloat.zero, max(0, textView.bounds.height - controller.scrollView.contentSize.height)] {
                    controller.scrollView.contentView.scroll(to: CGPoint(x: 0, y: offset))
                    controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
                    await settle(content)
                    // TextView.visibleRect is an overscanned layout range (it
                    // adds contentInsets), not AppKit's actual drawing clip.
                    for view in [controller.scrollView as NSView, controller.gutterView as NSView] {
                        let visible = view.convert(view.visibleRect, to: content)
                        #expect(viewport.insetBy(dx: -1, dy: -1).contains(visible))
                    }
                    #expect(textView.string == source)
                }
            }
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    Attachment.record(data, named: "template-viewport-\(scheme == .dark ? "dark" : "light").png")
                }
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private struct TemplateManagerSheetHarness: View {
    let model: WorkspaceModel
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                WorkspaceElasticsearchIndexTemplateManagerSheet(
                    model: model,
                    dismiss: { isPresented = false }
                )
            }
    }
}
