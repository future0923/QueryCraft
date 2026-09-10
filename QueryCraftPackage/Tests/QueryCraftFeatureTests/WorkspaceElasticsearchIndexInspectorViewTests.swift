import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@Suite(.serialized) @MainActor
struct WorkspaceElasticsearchIndexInspectorViewTests {
    @Test func indexInspectorKeepsItsRectangleAcrossLoadingEditingAndAppearance() async throws {
        let (workspace, _) = await indexDeletionFixture()
        workspace.safetyLock.disable()
        for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let editor = WorkspaceElasticsearchIndexInspectorModel()
            let context = WorkspaceInspectorContext.elasticsearchIndex(.init(selection: indexSelection("logs"), editor: editor,
                aliasEditor: WorkspaceElasticsearchAliasEditor(), workspace: workspace))
            let view = NSHostingView(rootView: WorkspaceInspectorView(context: context).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 760),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            await settle(view)
            let initial = view.frame.size
            #expect(initial == CGSize(width: 320, height: 760))
            await editor.load { try await settingsSnapshot() }
            await settle(view)
            #expect(view.frame.size == initial)
            editor.requestEdit(workspace: workspace)
            editor.update(replicas: "2", interval: "5s", workspace: workspace)
            await waitForSettings { editor.prepared != nil }
            await settle(view)
            #expect(view.frame.size == initial && editor.hasChanges)
            #expect(context.searchIdentity == "elasticsearch-index:\(indexSelection("logs").id)")
            editor.discard()
            await settle(view)
            #expect(view.frame.size == initial && !editor.hasChanges)
        }
        await workspace.disconnect()
    }

    @Test func aliasSectionKeepsInspectorSizeWhileAddingAndDiscarding() async throws {
        let (workspace, _) = await indexDeletionFixture()
        workspace.safetyLock.disable()
        let selection = indexSelection("logs")
        let settings = WorkspaceElasticsearchIndexInspectorModel()
        let aliases = WorkspaceElasticsearchAliasEditor()
        await settings.load { try await settingsSnapshot() }
        await aliases.load {
            WorkspaceElasticsearchAliasSnapshot(selection: selection, bindings: [], rawJSON: Data("{}".utf8))
        }
        let context = WorkspaceInspectorContext.elasticsearchIndex(.init(selection: selection,
            editor: settings, aliasEditor: aliases, workspace: workspace))
        let view = NSHostingView(rootView: WorkspaceInspectorView(context: context))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 760),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(view)
        let acceptedSize = view.frame.size
        aliases.beginAdding(workspace: workspace)
        aliases.newBindingName = "current"
        aliases.addBinding(workspace: workspace)
        await waitForSettings { aliases.prepared != nil }
        await settle(view)
        #expect(aliases.hasChanges && view.frame.size == acceptedSize)
        aliases.discard()
        await settle(view)
        #expect(!aliases.hasChanges && aliases.rows.isEmpty && view.frame.size == acceptedSize)
        await workspace.disconnect()
    }
    private func settle(_ view: NSView) async {
        await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        view.layoutSubtreeIfNeeded()
    }
}
