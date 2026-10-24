import SwiftUI

struct MobileRedisConsoleView: View {
    @Bindable var console: MobileRedisConsole
    @Bindable var document: WorkspaceRedisCommandDocumentModel
    let close: () -> Void
    @State private var confirmDiscard = false
    @State private var inputRevision = UUID()
    var body: some View {
        NavigationStack {
            Form {
                Section("DB \(console.database)" + (console.transactionOpen ? " · MULTI 未提交" : "")) {
                    Toggle("安全锁", isOn: Binding(get: { console.safetyLock.isEnabled }, set: { if $0 { console.safetyLock.enable() } else { console.safetyLock.disable() } }))
                        .disabled(document.isExecuting || console.isBackgrounded)
                    MobileSegmentedTextEditor(text: Binding(get: { document.source }, set: { document.updateSource($0) }), accessibilityIdentifier: "redisConsoleInput")
                        .id(inputRevision)
                        .disabled(!console.canRun)
                    if let command = document.activeCommand { Text(command.syntax).font(.caption).foregroundStyle(.secondary) }
                    if !document.completions.isEmpty {
                        ScrollView(.horizontal) { HStack { ForEach(document.completions.prefix(8)) { entry in Button(entry.name) { document.acceptCompletion(entry) } } } }.disabled(!console.canRun)
                    }
                    if !document.argumentSuggestions.isEmpty {
                        ScrollView(.horizontal) { HStack { ForEach(document.argumentSuggestions.prefix(8)) { suggestion in Button(suggestion.value) { document.acceptArgumentSuggestion(suggestion) } } } }.disabled(!console.canRun)
                    }
                    HStack {
                        Button("上一条") { _ = document.showPreviousCommand(); inputRevision = UUID() }
                        Button("下一条") { _ = document.showNextCommand(); inputRevision = UUID() }
                        Spacer()
                        if document.requiresSafetyLockDisable { Button("预览命令", action: console.prepare) }
                        else { Button("执行") { console.run() }.accessibilityIdentifier("redisConsoleRun") }
                    }.disabled(!console.canRun)
                }
                if let preview = console.preview {
                    Section("确认执行 · DB \(console.database)") {
                        Text(String(preview.prefix(65_536)) + (preview.count > 65_536 ? "\n…（预览显示前缀；确认绑定完整输入，执行完整命令）" : "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("写入和未知命令须解锁并确认。事务命令在当前连接执行；关闭会话会丢弃未 EXEC 的事务。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("确认执行") { console.run() }.disabled(!console.canRun || console.safetyLock.isEnabled)
                    }
                }
                Section("执行记录") {
                    ForEach(document.transcriptEntries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DB \(entry.databaseIndex) > " + String(entry.command.prefix(16_384)) + (entry.command.count > 16_384 ? "…（命令记录显示前缀）" : "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(8)
                            switch entry.outcome {
                            case .executing: Text("执行中…").foregroundStyle(.secondary)
                            case .success(let reply, let seconds):
                                Text(reply.boundedText()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(120)
                                Text(String(format: "%.3f s", seconds)).font(.caption2).foregroundStyle(.secondary)
                            case .failure(let message): Text(message).foregroundStyle(.red)
                            case .cancelled: Text("已取消").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    ProgressView().controlSize(.small).opacity(document.isExecuting || console.isVerifying || console.isClosingConnection ? 1 : 0)
                    Text(console.message ?? (console.needsVerification ? "执行结果未知。先读取核实，不可直接重放。" : "记录限 4 MiB，大回复保留前缀，每条最多展示 120 行。历史输入保留完整命令。"))
                        .font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if console.needsVerification { Button("读取核实") { console.verify() }.disabled(document.isExecuting || console.isBackgrounded || console.isVerifying) }
                }.padding(.horizontal, 16).frame(height: 72).background(.bar)
            }
            .navigationTitle("Redis 命令").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("完成") { if console.transactionOpen || !document.source.isEmpty { confirmDiscard = true } else { close() } }.disabled(!console.canClose)
            } }
            .confirmationDialog("关闭会话并丢弃未执行命令和未 EXEC 的事务？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("关闭会话", role: .destructive, action: close)
            }
        }.interactiveDismissDisabled()
        .onChange(of: document.executionRevision) { _, _ in inputRevision = UUID() }
    }
}
