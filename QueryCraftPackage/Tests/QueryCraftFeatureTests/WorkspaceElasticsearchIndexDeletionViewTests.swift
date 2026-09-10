import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@Suite(.serialized) @MainActor
struct WorkspaceElasticsearchIndexDeletionViewTests {
    @Test func nativeConfirmationMountsWithStableGeometryAndNoDestructiveReturnShortcut() async throws {
        let model = WorkspaceModel(profileID: UUID(), repository: InMemoryConnectionProfileRepository(profiles: []),
            credentialStore: InMemoryCredentialStore(), sessionFactory: InMemoryWorkspaceSessionFactory(databases: []))
        var height: CGFloat?
        for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let view = NSHostingView(rootView: WorkspaceElasticsearchIndexDeletionSheet(
                selection: indexSelection("qc_delete_ui"), model: model,
                didDelete: { _ in Issue.record("Mounting must not delete") }, dismiss: {}
            ).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 330),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width == 580)
            if let height { #expect(view.fittingSize.height == height) } else { height = view.fittingSize.height }
            let controls = descendants(view)
            #expect(controls.contains { ($0 as? NSTextField)?.isEditable == true })
            #expect(!controls.compactMap { $0 as? NSButton }.contains { $0.keyEquivalent == "\r" })
            window.close()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
