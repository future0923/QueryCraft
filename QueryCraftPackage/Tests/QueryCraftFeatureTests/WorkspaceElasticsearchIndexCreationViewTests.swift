import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@Suite(.serialized) @MainActor
struct WorkspaceElasticsearchIndexCreationViewTests {
    @Test func nativeFormAndJSONEditorMountInBothAppearances() async throws {
        let model = WorkspaceModel(profileID: UUID(),
            repository: InMemoryConnectionProfileRepository(profiles: []),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["Elasticsearch"]))
        for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let view = NSHostingView(rootView: WorkspaceElasticsearchIndexCreationSheet(
                model: model, openIndex: { _ in }, dismiss: {}
            ).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 570),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
            view.layoutSubtreeIfNeeded()
            let textFields = descendants(of: view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            // The JSON editor also owns native text controls. Do not treat its
            // internal controls as additional index-setting fields.
            #expect(textFields.count >= 3)
            #expect(textFields.allSatisfy { $0.bounds.width > 100 && $0.bounds.height > 10 })
            #expect(view.fittingSize.width == 640)
            #expect(view.fittingSize.height == 570)
            window.close()
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
