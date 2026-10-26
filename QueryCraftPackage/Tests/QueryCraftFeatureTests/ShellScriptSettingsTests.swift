import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
struct ShellScriptSettingsTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "qc-shell-ui-" + UUID().uuidString) }
    @Test func editorAndMCPShareRecordsAndRejectConcurrentEdits() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = ShellScriptLibraryService(directory: root)
        let draft = ShellScriptDraft(); draft.name = "Health"; draft.description = "literal"; draft.script = "printf '你好\\n'\n"
        #expect(await draft.save(service: service))
        let original = try #require(try ShellScriptStore(directory: root).load().first)
        var policy = MCPPolicy(); policy.enabled = true
        try MCPPolicyStore(directory: root).save(policy)
        let runtime = MCPRuntime(directory: root)
        let mcpRead = try await runtime.call("querycraft_shell_get", arguments: ["script_id": .string(original.id.uuidString)])
        #expect(mcpRead.objectValue?["script"] == .string(draft.script))
        let editing = ShellScriptDraft(original: original); editing.script = "local unsaved source"
        _ = try await runtime.call("querycraft_shell_update", arguments: ["script_id": .string(original.id.uuidString), "expected_revision": 1, "script": "MCP changed source"])
        #expect(await editing.save(service: service) == false)
        #expect(editing.script == "local unsaved source" && editing.error != nil)
        let model = ShellScriptSettingsModel(service: service)
        await model.load(); #expect(model.records.first?.revision == 2)
        await model.remove(original)
        #expect(model.records.count == 1 && model.error != nil)
        await model.load(); #expect(model.error != nil) // polling must not erase a mutation error
        await model.retry(); #expect(model.error == nil)
        let current = try #require(model.records.first)
        #expect(await model.current(original, requireRevision: true) == nil)
        #expect(await model.current(current, requireRevision: true)?.script == "MCP changed source")
        await model.remove(current); #expect(model.records.isEmpty)
        await runtime.shutdown()
    }
    @Test func refreshDetectsExternalChangesAndRetainsContentOnFailure() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ShellScriptStore(directory: root), service = ShellScriptLibraryService(directory: root)
        let record = try store.create(name: "initial", description: "", script: "echo ok")
        let model = ShellScriptSettingsModel(service: service)
        await model.load(); #expect(model.loaded && model.records == [record])
        _ = try store.update(id: record.id, revision: 1, name: "external", description: nil, script: nil)
        await model.load(); #expect(model.records.first?.name == "external")
        try Data("broken".utf8).write(to: store.url)
        await model.load()
        #expect(model.loaded && model.records.first?.name == "external" && model.error != nil)
        let first = ShellScriptSettingsModel(service: service)
        await first.load(); #expect(!first.loaded && first.records.isEmpty && first.error != nil)
    }
    @Test func staleResponsesCannotReplaceTheLatestSnapshot() async throws {
        let service = ShellSnapshotGate()
        let model = ShellScriptSettingsModel(service: service)
        let older = Task { await model.load() }
        await service.waitForFirst()
        await model.load(force: true)
        await service.releaseFirst()
        await older.value
        #expect(model.records.first?.name == "new" && !model.loading)
    }
    @Test func validationAndUnsavedDraftAreIndependentOfListRefresh() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let service = ShellScriptLibraryService(directory: root)
        let draft = ShellScriptDraft()
        #expect(!draft.valid && !draft.hasChanges)
        draft.name = "script"; draft.script = "echo 'literal'\n"
        #expect(draft.valid && draft.hasChanges)
        let model = ShellScriptSettingsModel(service: service)
        await model.load(); #expect(model.loaded && model.records.isEmpty)
        #expect(draft.script == "echo 'literal'\n")
        draft.script += "\0"
        #expect(!draft.valid)
        #expect(await draft.save(service: service) == false)
        #expect(try ShellScriptStore(directory: root).load().isEmpty)
    }
    @Test func nativeEditorPreservesLiteralSyntaxAndDisablesSubstitutions() {
        let source = "printf '%s\\n' \"$HOME\"\n# -- and 'quotes'\n"
        let host = NSHostingView(rootView: ShellScriptSourceEditor(text: .constant(source)))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 220); host.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
        let editor = editors(host).first
        #expect(editor != nil && editor?.string == source)
        #expect(editor?.isRichText == false && editor?.allowsUndo == true)
        #expect(editor?.isAutomaticQuoteSubstitutionEnabled == false)
        #expect(editor?.isAutomaticDashSubstitutionEnabled == false)
        #expect(editor?.isAutomaticTextReplacementEnabled == false)
    }
}

private actor ShellSnapshotGate: ShellScriptLibraryServing {
    private var first: CheckedContinuation<[ShellScript], Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var started = false
    func waitForFirst() async { if !started { await withCheckedContinuation { waiting = $0 } } }
    func list(force: Bool) async throws -> [ShellScript] {
        if !force {
            return await withCheckedContinuation { continuation in
                first = continuation; started = true; waiting?.resume(); waiting = nil
            }
        }
        return [record("new")]
    }
    func releaseFirst() { first?.resume(returning: [record("old")]); first = nil }
    private func record(_ name: String) -> ShellScript { .init(id: UUID(), name: name, description: "", script: "echo ok", revision: 1, createdAt: Date(), updatedAt: Date()) }
    func save(original: ShellScript?, name: String, description: String, script: String) throws -> ShellScript { throw MCPFailure("unused") }
    func remove(_ script: ShellScript) throws { throw MCPFailure("unused") }
}
