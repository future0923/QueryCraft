import SwiftUI
import Observation
import UIKit

/// Keeps native selection/navigation in the editor while exposing touch controls.
@MainActor @Observable final class MobileSQLSnippetContext {
    private(set) var currentIndex = 0
    private(set) var count = 0
    private(set) var isComposing = false
    @ObservationIgnored private weak var editor: MobileSQLTextView?
    var isActive: Bool { count > 0 }
    func attach(_ editor: MobileSQLTextView) { self.editor = editor }
    func detach(_ editor: MobileSQLTextView) { if self.editor === editor { self.editor = nil; count = 0 } }
    func update(session: SQLSnippetSession, composing: Bool) {
        currentIndex = session.currentIndex; count = session.isActive ? session.placeholderRanges.count : 0; isComposing = composing
    }
    func move(_ delta: Int) { guard !isComposing else { return }; _ = editor?.navigateSnippet?(delta) }
    func end() { _ = editor?.endSnippet?() }
}

struct MobileSQLSnippetControls: View {
    @Bindable var context: MobileSQLSnippetContext
    var body: some View {
        if context.isActive {
            Button { context.move(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44).contentShape(.rect) }
                .accessibilityLabel("上一个待填写位置").disabled(context.isComposing)
            Text("\(context.currentIndex + 1)/\(context.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { context.move(1) } label: {
                Image(systemName: context.currentIndex + 1 == context.count ? "checkmark" : "chevron.right").frame(width: 36, height: 44).contentShape(.rect)
            }.accessibilityLabel(context.currentIndex + 1 == context.count ? "完成代码片段" : "下一个待填写位置")
                .disabled(context.isComposing)
        }
    }
}

struct MobileSQLSnippetsView: View {
    @Bindable var store: SQLSnippetStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SQLSnippet?
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.snippets) { snippet in
                        HStack {
                            Button { editing = snippet } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(snippet.name).foregroundStyle(.primary)
                                    Text(snippet.trigger).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(SQLSnippetTemplate(content: snippet.content).previewText)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                            }.buttonStyle(.plain)
                            Toggle("启用 \(snippet.name)", isOn: Binding(get: {
                                store.snippets.first { $0.id == snippet.id }?.isEnabled ?? false
                            }, set: { enabled in
                                guard var current = store.snippets.first(where: { $0.id == snippet.id }) else { return }
                                current.isEnabled = enabled; store.update(current)
                            })).labelsHidden()
                        }
                    }.onDelete { offsets in
                        let ids = offsets.map { store.snippets[$0].id }
                        for id in ids { store.remove(id: id) }
                    }
                    if store.snippets.isEmpty { Text("还没有代码片段，点右上角添加。").foregroundStyle(.secondary) }
                } footer: {
                    Text("在 SQL 编辑器输入缩写（例如 sel），点选候选展开模板。${名称} 是待填写位置，可用上一项／下一项或 Tab／Shift-Tab 跳转。片段保存在当前设备，SQL 执行权限保持不变。")
                }
                Section { Button("恢复默认片段", role: .destructive) { restoring = true } }
            }
            .navigationTitle("代码片段").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .init(name: "", trigger: "", content: "") } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新增代码片段")
                }
            }
            .sheet(item: $editing) { snippet in MobileSQLSnippetEditor(store: store, snippet: snippet) }
            .confirmationDialog("恢复默认片段将替换当前设备的全部片段。", isPresented: $restoring, titleVisibility: .visible) {
                Button("恢复默认片段", role: .destructive) { store.restoreDefaults() }
            }
        }
    }
}

struct MobileSQLSnippetEditor: View {
    @Bindable var store: SQLSnippetStore
    let snippet: SQLSnippet
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var trigger: String
    @State private var content: String
    @State private var enabled: Bool

    init(store: SQLSnippetStore, snippet: SQLSnippet) {
        self.store = store; self.snippet = snippet
        _name = State(initialValue: snippet.name); _trigger = State(initialValue: snippet.trigger)
        _content = State(initialValue: snippet.content); _enabled = State(initialValue: snippet.isEnabled)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var triggerError: String? {
        switch store.triggerIssue(trimmedTrigger, excluding: snippet.id) {
        case .required: "请输入缩写"
        case .whitespace: "缩写不能包含空白字符"
        case .duplicate: "已存在相同缩写（不区分大小写）"
        case nil: nil
        }
    }
    private var canSave: Bool { !trimmedName.isEmpty && triggerError == nil && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("缩写，如 sel", text: $trigger).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    if let triggerError, !trigger.isEmpty { Text(triggerError).font(.caption).foregroundStyle(.red) }
                    Toggle("启用", isOn: $enabled)
                }
                Section {
                    MobileSQLSnippetContentInput(text: $content).frame(minHeight: 200)
                        .accessibilityLabel("SQL 模板内容")
                } header: { Text("模板内容") } footer: { Text("用 ${table}、${column} 等标记待填写的位置。支持多行 SQL。") }
            }
            .navigationTitle("编辑代码片段").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = SQLSnippet(id: snippet.id, name: trimmedName, trigger: trimmedTrigger, content: content, isEnabled: enabled)
                        if store.snippets.contains(where: { $0.id == value.id }) { store.update(value) } else { store.add(value) }
                        dismiss()
                    }.disabled(!canSave)
                }
            }
        }
    }
}

/// Template punctuation must stay literal, including quotes and `${...}`.
private struct MobileSQLSnippetContentInput: UIViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.backgroundColor = .clear
        view.autocapitalizationType = .none; view.autocorrectionType = .no; view.spellCheckingType = .no
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .onDrag; view.accessibilityLabel = "SQL 模板内容"
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text, view.markedTextRange == nil { view.text = text }
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) { view.delegate = nil }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileSQLSnippetContentInput
        init(_ parent: MobileSQLSnippetContentInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
