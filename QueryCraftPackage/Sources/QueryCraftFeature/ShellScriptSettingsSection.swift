import AppKit
import SwiftUI

struct ShellScriptSettingsSection: View {
    @State var model: ShellScriptSettingsModel
    @State private var draft: ShellScriptDraft?
    @State private var removing: ShellScript?
    @State private var operation: Task<Void, Never>?
    init(model: ShellScriptSettingsModel = ShellScriptSettingsModel()) { _model = State(initialValue: model) }
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        @Bindable var model = model
        Section(copy("Shell 脚本", "Shell scripts")) {
            HStack(spacing: 10) {
                TextField(copy("搜索脚本名称或说明", "Search script names or descriptions"), text: $model.search, prompt: Text(copy("搜索脚本名称或说明", "Search script names or descriptions")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(copy("搜索 Shell 脚本", "Search Shell scripts"))
                ProgressView().controlSize(.small).frame(width: 16).opacity(model.loading || model.busy ? 1 : 0)
                Button(copy("新建", "New"), systemImage: "plus") { draft = ShellScriptDraft() }.disabled(model.busy)
            }.frame(height: 30)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.filtered) { record in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).font(.body.weight(.medium)).lineLimit(1).help(record.name)
                                Text(record.description.isEmpty ? copy("未填写说明", "No description") : record.description)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(record.description)
                            }
                            Spacer(minLength: 6)
                            Button(copy("复制", "Copy")) {
                                operation = Task {
                                    if let current = await model.current(record, requireRevision: true) {
                                        NSPasteboard.general.clearContents()
                                        if NSPasteboard.general.setString(current.script, forType: .string) {
                                            model.status = copy("已复制脚本正文。", "Script source copied.")
                                        } else { model.actionError = copy("无法复制脚本，请重试。", "Cannot copy the script. Please try again.") }
                                    }
                                }
                            }
                            Button(copy("编辑", "Edit")) {
                                operation = Task { if let current = await model.current(record) { draft = ShellScriptDraft(original: current) } }
                            }
                            Button(role: .destructive) { removing = record } label: { Image(systemName: "trash") }
                                .help(copy("删除脚本", "Delete script"))
                                .accessibilityLabel(copy("删除脚本", "Delete script"))
                        }.padding(.vertical, 8).disabled(model.busy)
                        Divider()
                    }
                    if model.loaded && model.filtered.isEmpty {
                        Text(model.records.isEmpty ? copy("尚未保存脚本。点击“新建”添加，也可以通过 MCP 保存。", "No saved scripts. Choose New or save one through MCP.") : copy("没有匹配的脚本。", "No matching scripts."))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 14)
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(height: 205)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.error ?? model.status).font(.caption).lineLimit(2)
                    .foregroundStyle(model.error == nil ? Color.secondary : .red)
                if model.error != nil {
                    Button(copy("重试", "Retry")) { operation = Task { await model.retry() } }.controlSize(.small)
                }
            }.frame(height: 48, alignment: .topLeading)
            Text(copy("与 MCP 共用脚本库，修改保存后生效。这里只保存和复制，不会运行脚本。", "Shares the MCP script library; saved edits take effect immediately. Saving and copying do not run scripts."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            await model.load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await model.load()
            }
        }
        .onDisappear { operation?.cancel() }
        .sheet(item: $draft, onDismiss: { operation = Task { await model.load(force: true) } }) { value in
            ShellScriptEditor(draft: value, service: model.service)
        }
        .confirmationDialog(copy("删除 Shell 脚本？", "Delete Shell script?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { record in
            Button(copy("删除", "Delete"), role: .destructive) {
                removing = nil; operation = Task { await model.remove(record) }
            }
        } message: { record in
            Text(copy("删除“\(record.name)”的本机记录，不影响远程文件或正在运行的任务。", "Delete the local record “\(record.name)”. Remote files and running tasks are unaffected."))
        }
    }
}

struct ShellScriptEditor: View {
    @Bindable var draft: ShellScriptDraft
    let service: any ShellScriptLibraryServing
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var nameFocused: Bool
    @State private var operation: Task<Void, Never>?
    @State private var discarding = false
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var footerMessage: String {
        draft.error ?? (draft.hasChanges && !draft.valid
            ? copy("请填写名称和脚本内容，正文最多 64 KiB。", "Enter a name and script within the 64 KiB limit.")
            : copy("保存不会执行脚本。", "Saving does not run the script."))
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(draft.original == nil ? copy("新建 Shell 脚本", "New Shell Script") : copy("编辑 Shell 脚本", "Edit Shell Script"))
                    .font(.headline)
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text(copy("名称", "Name")).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        TextField(copy("脚本名称", "Script name"), text: $draft.name)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                            .focused($nameFocused).accessibilityLabel(copy("脚本名称", "Script name"))
                    }
                    HStack(spacing: 12) {
                        Text(copy("说明", "Notes")).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        TextField(copy("可选", "Optional"), text: $draft.description)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                            .accessibilityLabel(copy("脚本说明", "Script description"))
                    }
                }.disabled(draft.busy)
                VStack(spacing: 8) {
                    HStack {
                        Text(copy("脚本内容", "Script")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(draft.script.utf8.count) + copy(" / 65536 字节", " / 65536 bytes"))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(draft.script.utf8.count > 65_536 ? Color.red : .secondary)
                    }
                    ShellScriptSourceEditor(text: $draft.script)
                        .disabled(draft.busy)
                        .overlay(alignment: .topLeading) {
                            if draft.script.isEmpty {
                                Text(copy("输入 Shell 脚本…", "Enter a Shell script…"))
                                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12).padding(.vertical, 10).allowsHitTesting(false)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
                }.frame(maxHeight: .infinity)
            }.padding(18)
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).frame(width: 14, height: 14).opacity(draft.busy ? 1 : 0)
                Text(footerMessage).font(.caption).lineLimit(2).help(footerMessage)
                    .foregroundStyle(draft.error == nil ? Color.secondary : .red)
                Spacer(minLength: 8)
                Button(copy("取消", "Cancel")) {
                    if draft.hasChanges { discarding = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(draft.busy)
                Button(copy("保存", "Save")) {
                    operation = Task { if await draft.save(service: service) { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(draft.busy || !draft.valid || !draft.hasChanges)
            }.controlSize(.regular).padding(.horizontal, 18).frame(height: 54)
        }
        .frame(width: 660, height: 520)
        .background(colorScheme == .dark ? Color.black : Color(nsColor: .windowBackgroundColor))
        .onAppear { if draft.original == nil { nameFocused = true } }
        .interactiveDismissDisabled(draft.hasChanges || draft.busy)
        .onDisappear { operation?.cancel() }
        .confirmationDialog(copy("放弃未保存的修改？", "Discard unsaved changes?"), isPresented: $discarding) {
            Button(copy("放弃修改", "Discard changes"), role: .destructive) { dismiss() }
            Button(copy("继续编辑", "Keep editing"), role: .cancel) {}
        }
    }
}

/// A native plain-text editor with smart substitutions disabled so copying and
/// saving preserve literal shell syntax, undo and the user's caret/scroll state.
struct ShellScriptSourceEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.autohidesScrollers = true; scroll.drawsBackground = true
        let editor = NSTextView()
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false; editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false; editor.usesFindBar = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = .textColor; editor.backgroundColor = canvasColor
        scroll.backgroundColor = canvasColor
        editor.textContainerInset = NSSize(width: 12, height: 10)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator; editor.string = text
        editor.setAccessibilityLabel(AppCopy.current.text("脚本正文", "Script source"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = context.environment.isEnabled
        if editor.backgroundColor != canvasColor { editor.backgroundColor = canvasColor }
        if scroll.backgroundColor != canvasColor { scroll.backgroundColor = canvasColor }
        guard editor.string != text else { return }
        let selection = editor.selectedRange()
        editor.string = text
        editor.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
    }
    private var canvasColor: NSColor { colorScheme == .dark ? .black : .textBackgroundColor }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ShellScriptSourceEditor
        init(_ parent: ShellScriptSourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}
