import SwiftUI
import UIKit
import QueryCraftMobileCore

struct MobileSchemaTextField: View {
    let title: String
    @Binding var text: String
    var suggestions: [String] = []
    @FocusState private var focused: Bool
    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $text).multilineTextAlignment(.trailing).focused($focused).submitLabel(.done)
                    .accessibilityIdentifier("schemaInput." + title)
                    .onSubmit { focused = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                if !suggestions.isEmpty {
                    Menu { ForEach(suggestions, id: \.self) { value in Button(value.isEmpty ? "默认" : value) { text = value } } }
                    label: { Image(systemName: "chevron.up.chevron.down").font(.caption) }.accessibilityLabel(title + "选项")
                }
            }
        }
    }
}

struct MobileSchemaEditSelection: Identifiable {
    let id = UUID()
    let itemID: UUID
    let epoch: UUID
    let section: MobileSchemaDraft.Section
    var added = false
}

struct MobileSchemaColumnEditor: View {
    let controller: MobileSchemaController
    @Bindable var draft: MobileSchemaDraft
    let selection: MobileSchemaEditSelection
    let close: () -> Void
    @State private var definition: WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    @State private var primary: Bool
    init(controller: MobileSchemaController, draft: MobileSchemaDraft, selection: MobileSchemaEditSelection, close: @escaping () -> Void) {
        self.controller = controller; self.draft = draft; self.selection = selection; self.close = close
        _definition = State(initialValue: draft.state.columns.first { $0.id == selection.itemID }?.definition ?? .init())
        _primary = State(initialValue: draft.state.isPrimaryKey(columnID: selection.itemID))
    }
    private var editable: Bool { draft.epoch == selection.epoch && controller.canEdit(draft) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MobileSchemaTextField(title: "名称", text: $definition.name)
                    MobileSchemaTextField(title: "类型", text: $definition.type, suggestions: MySQLSchemaEditingProvider().descriptor.columnTypes)
                    Toggle("主键", isOn: $primary)
                    Toggle("允许 NULL", isOn: $definition.isNullable).disabled(primary)
                    Toggle("自增", isOn: $definition.isAutoIncrement).disabled(definition.isGenerated)
                }
                Section("默认值") {
                    Picker("方式", selection: $definition.defaultMode) {
                        Text("无").tag(WorkspaceDatabaseSchemaEditorState.DefaultMode.none)
                        Text("NULL").tag(WorkspaceDatabaseSchemaEditorState.DefaultMode.null)
                        Text("值").tag(WorkspaceDatabaseSchemaEditorState.DefaultMode.value)
                        Text("表达式").tag(WorkspaceDatabaseSchemaEditorState.DefaultMode.expression)
                    }
                    if definition.defaultMode == .value || definition.defaultMode == .expression {
                        MobileSchemaTextField(title: "默认值", text: $definition.defaultValue)
                    }
                    MobileSchemaTextField(title: "更新表达式", text: $definition.onUpdateExpression, suggestions: ["", "CURRENT_TIMESTAMP"])
                }
                Section {
                    MobileSchemaTextField(title: "注释", text: $definition.comment)
                    Toggle("可见", isOn: $definition.isVisible)
                }
                Section("生成列") {
                    Picker("存储", selection: $definition.generatedStorage) {
                        Text("普通列").tag(WorkspaceDatabaseSchemaEditorState.GeneratedStorage.none)
                        Text("VIRTUAL").tag(WorkspaceDatabaseSchemaEditorState.GeneratedStorage.virtual)
                        Text("STORED").tag(WorkspaceDatabaseSchemaEditorState.GeneratedStorage.stored)
                    }
                    if definition.isGenerated { MobileSchemaTextField(title: "表达式", text: $definition.generationExpression) }
                }
                if definition.supportsCharacterSetAndCollation {
                    Section("字符设置") {
                        MobileSchemaTextField(title: "字符集", text: Binding(get: { definition.characterSet }, set: { definition.applyCharacterSet($0, choices: draft.state.schemaChoices) }), suggestions: [""] + draft.state.schemaChoices.characterSets)
                        MobileSchemaTextField(title: "排序规则", text: Binding(get: { definition.collation }, set: { definition.applyCollation($0, choices: draft.state.schemaChoices) }), suggestions: [""] + draft.state.schemaChoices.collations.filter { definition.characterSet.isEmpty || $0.characterSet == definition.characterSet }.map(\.name))
                    }
                }
                if !selection.added { Section { Button("暂存删除字段", role: .destructive) { guard editable else { return }; draft.delete(selection.itemID); close() } } }
            }.disabled(!editable).textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(selection.added ? "新增字段" : "编辑字段").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { if selection.added, draft.epoch == selection.epoch { draft.delete(selection.itemID) }; close() } }
                ToolbarItem(placement: .confirmationAction) { Button("暂存") {
                    guard editable else { return }
                    draft.updateColumn(selection.itemID, definition: definition, primary: primary); close()
                }.disabled(!editable || definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || definition.type.isEmpty) }
            }
            .interactiveDismissDisabled(selection.added)
        }
    }
}

struct MobileSchemaIndexEditor: View {
    let controller: MobileSchemaController
    @Bindable var draft: MobileSchemaDraft
    let selection: MobileSchemaEditSelection
    let close: () -> Void
    @State private var definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition
    init(controller: MobileSchemaController, draft: MobileSchemaDraft, selection: MobileSchemaEditSelection, close: @escaping () -> Void) {
        self.controller = controller; self.draft = draft; self.selection = selection; self.close = close
        _definition = State(initialValue: draft.state.indexes.first { $0.id == selection.itemID }?.definition ?? .init(firstColumnName: nil))
    }
    private var editable: Bool { draft.epoch == selection.epoch && controller.canEdit(draft) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MobileSchemaTextField(title: "名称", text: $definition.name)
                    Picker("种类", selection: $definition.kind) {
                        ForEach(WorkspaceDatabaseSchemaChoiceCatalog.indexKinds) { Text($0.title).tag(WorkspaceDatabaseSchemaEditorState.IndexKind(rawValue: $0.value)!) }
                    }
                    if definition.kind != .fulltext && definition.kind != .spatial { MobileSchemaTextField(title: "方法", text: $definition.method, suggestions: MySQLSchemaEditingProvider().descriptor.indexMethods) }
                    Toggle("可见", isOn: $definition.isVisible)
                    MobileSchemaTextField(title: "注释", text: $definition.comment)
                }
                Section {
                    ForEach($definition.columns) { $column in
                        VStack {
                            if column.isExpression { MobileSchemaTextField(title: "表达式", text: $column.name) }
                            else {
                                Picker("字段", selection: $column.name) {
                                    Text("选择字段").tag("")
                                    ForEach(draft.state.columns.filter { !$0.isDeleted }) { Text($0.definition.name).tag($0.definition.name) }
                                }.onChange(of: column.name) { _, name in column.sourceColumnID = draft.state.columns.first { $0.definition.name == name && !$0.isDeleted }?.id }
                                MobileSchemaTextField(title: "前缀长度", text: $column.prefixLength)
                            }
                            Toggle("表达式字段", isOn: $column.isExpression)
                            Toggle("降序", isOn: $column.isDescending)
                        }.padding(.vertical, 4)
                    }.onDelete { definition.columns.remove(atOffsets: $0) }
                        .onMove { definition.columns.move(fromOffsets: $0, toOffset: $1) }
                    Button("添加索引字段", systemImage: "plus") {
                        let first = draft.state.columns.first { !$0.isDeleted }
                        definition.columns.append(.init(name: first?.definition.name ?? "", sourceColumnID: first?.id))
                    }
                } header: { Text("索引字段 · 长按右侧拖动排序") } footer: { Text("索引字段的顺序、前缀长度和排序方向与 Mac 使用同一模型。") }
                if !selection.added { Section { Button("暂存删除索引", role: .destructive) { guard editable else { return }; draft.delete(selection.itemID); close() } } }
            }.environment(\.editMode, .constant(.active)).disabled(!editable)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(selection.added ? "新增索引" : "编辑索引").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { if selection.added, draft.epoch == selection.epoch { draft.delete(selection.itemID) }; close() } }
                    ToolbarItem(placement: .confirmationAction) { Button("暂存") {
                        guard editable else { return }; draft.updateIndex(selection.itemID, definition: definition); close()
                    }.disabled(!editable || (definition.kind != .primary && definition.name.isEmpty) || definition.columns.isEmpty || definition.columns.contains { $0.name.isEmpty }) }
                }
                .interactiveDismissDisabled(selection.added)
        }
    }
}

private struct MobileSchemaPreviewStep: Identifiable {
    let id = UUID()
    let sql: String
}
struct MobileSchemaPendingView: View {
    let controller: MobileSchemaController
    @Bindable var draft: MobileSchemaDraft
    let close: () -> Void
    @State private var unlock = false
    @State private var discard = false
    @State private var steps: [MobileSchemaPreviewStep]
    init(controller: MobileSchemaController, draft: MobileSchemaDraft, close: @escaping () -> Void) {
        self.controller = controller; self.draft = draft; self.close = close
        // Immutable preview of this presented operation; not regenerated during loading.
        _steps = State(initialValue: draft.plan.statements.map { .init(sql: $0.sql) })
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(draft.object.database + "." + draft.object.name).font(.subheadline)
                    ForEach(steps) { statement in
                        Text(statement.sql + ";").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                } header: { Text("结构变更 SQL") } footer: { Text("按预览顺序执行。MySQL 结构语句分别提交，失败或取消不能撤销已完成的语句。") }
                Section {
                    HStack {
                        ProgressView().opacity(controller.isSubmitting ? 1 : 0)
                        Text(draft.message ?? "确认后提交结构改动").font(.footnote).lineLimit(4)
                    }.frame(minHeight: 64)
                    if draft.needsVerification {
                        Text("请先核对服务器的实际结构。重新加载会结束此次操作并清除原草稿，不会重放 SQL。")
                        Button("已核对，重新加载结构") { discard = true }.disabled(controller.isSubmitting)
                    } else if draft.requiresReload {
                        Button("重新读取结构") { controller.load(draft.object) }.disabled(controller.isSubmitting)
                    } else {
                        Button("提交结构改动", role: .destructive) {
                            if controller.safetyLock.isEnabled { unlock = true } else { controller.submit(draft) }
                        }.disabled(!draft.hasChanges || !controller.canEdit(draft))
                        Button("撤销全部结构改动", role: .destructive) { discard = true }.disabled(controller.isSubmitting)
                    }
                }
            }.navigationTitle("待提交结构改动").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: close).disabled(controller.isSubmitting) } }
                .interactiveDismissDisabled(controller.isSubmitting)
                .onChange(of: draft.epoch) { _, _ in if !draft.hasChanges && !draft.needsVerification && !draft.requiresReload { close() } }
                .alert("停用安全锁？", isPresented: $unlock) {
                    Button("取消", role: .cancel) {}
                    Button("解锁并提交", role: .destructive) { controller.safetyLock.disable(); controller.submit(draft) }
                } message: { Text("允许执行已预览的表结构变更。") }
                .alert(draft.needsVerification ? "重新加载并结束此次操作？" : "撤销结构草稿？", isPresented: $discard) {
                    Button("取消", role: .cancel) {}
                    Button("确认", role: .destructive) {
                        if draft.needsVerification { controller.load(draft.object, reconcile: true) } else { draft.discard(); close() }
                    }
                } message: { Text("将清除本地结构草稿，服务器上已执行的操作不会撤销。") }
        }
    }
}
