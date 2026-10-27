import SwiftUI

struct SSHShellScriptsView: View {
    @Bindable var workspace: SSHTerminalWorkspace
    @State private var selection: UUID?
    @State private var draft: ShellScriptDraft?
    @State private var details: ShellScript?
    @State private var operation: Task<Void, Never>?
    private var model: ShellScriptSettingsModel { workspace.scripts }
    private var canSend: Bool { workspace.current?.state == .connected && !workspace.scriptDispatching && !model.busy }
    private func text(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.records) { script in
                    HStack(spacing: 8) {
                        Text(script.name).lineLimit(1).help(script.name)
                        Spacer(minLength: 4)
                        Button { workspace.useScript(script, execute: true) } label: { Image(systemName: "play.fill") }
                            .help(text("在当前 Shell 提示符下执行，替换当前输入", "Run at the current shell prompt, replacing pending input"))
                            .accessibilityLabel(text("执行脚本", "Run script")).disabled(!canSend)
                        Button { workspace.useScript(script, execute: false) } label: { Image(systemName: "doc.on.doc") }
                            .help(text("填入当前控制台，等待回车执行", "Insert in the console and wait for Return"))
                            .accessibilityLabel(text("填入控制台", "Insert in console")).disabled(!canSend)
                    }.buttonStyle(.borderless).padding(.vertical, 4).tag(script.id)
                        .contextMenu { menu(script) }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .overlay {
                if model.loaded && model.records.isEmpty && model.loadError == nil {
                    Text(text("右键新增 Shell 脚本", "Right-click to add a Shell script"))
                        .font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .contextMenu { menu(model.records.first { $0.id == selection }) }
            HStack(spacing: 6) {
                Text(model.error ?? model.status)
                    .foregroundStyle(model.error == nil ? Color.secondary : .red).lineLimit(2)
                    .help(model.error ?? model.status)
                Spacer(minLength: 0)
                ProgressView().controlSize(.mini).frame(width: 12, height: 12).opacity(model.loading || workspace.scriptDispatching ? 1 : 0)
            }.font(.caption).padding(.horizontal, 10).frame(height: 36)
        }
        .task {
            while !Task.isCancelled {
                await model.load()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onDisappear { operation?.cancel() }
        .sheet(item: $draft, onDismiss: { Task { await model.load(force: true) } }) { value in
            ShellScriptEditor(draft: value, service: model.service)
        }
        .sheet(item: $details) { script in SSHShellScriptDetails(script: script) }
        .accessibilityIdentifier("sshSavedScriptsInspector")
    }
    @ViewBuilder private func menu(_ script: ShellScript?) -> some View {
        Button(text("新增脚本…", "New Script…"), systemImage: "plus") { draft = ShellScriptDraft() }.disabled(model.busy)
        Button(text("查看详情…", "Show Details…"), systemImage: "info.circle") {
            if let script { operation = Task { details = await model.current(script, requireRevision: true) } }
        }.disabled(script == nil || model.busy)
        if let script {
            Divider()
            Button(text("执行", "Run"), systemImage: "play.fill") { workspace.useScript(script, execute: true) }.disabled(!canSend)
            Button(text("填入控制台", "Insert in Console"), systemImage: "doc.on.doc") { workspace.useScript(script, execute: false) }.disabled(!canSend)
        }
        if model.loadError != nil {
            Divider()
            Button(text("重新加载", "Reload")) { Task { await model.retry() } }
        }
    }
}

private struct SSHShellScriptDetails: View {
    let script: ShellScript
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(script.name).font(.headline).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !script.description.isEmpty { Text(script.description).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(script.script).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack { Spacer(); Button(AppCopy.current.text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 600, height: 440)
            .background(colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
    }
}
