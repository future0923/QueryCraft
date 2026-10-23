import SwiftUI

private struct MobileNewTablePreview: Identifiable {
    let id = UUID()
    let plan: WorkspaceDatabaseSchemaExecutionPlan
}

struct MobileNewTableView: View {
    let controller: MobileNewTableController
    @Bindable var draft: MobileNewTableDraft
    @State private var editing: MobileSchemaEditSelection?
    @State private var preview: MobileNewTablePreview?
    @State private var discard = false
    @State private var verify = false
    var body: some View {
        @Bindable var definition = draft.definition
        NavigationStack {
            Form {
                Section {
                    LabeledContent("数据库", value: definition.databaseName)
                    MobileSchemaTextField(title: "表名", text: $definition.tableName)
                    Picker("定义", selection: $definition.selectedTab) {
                        Text("字段").tag(WorkspaceDatabaseObjectDetailTab.structure)
                        Text("索引").tag(WorkspaceDatabaseObjectDetailTab.indexes)
                        Text("选项").tag(WorkspaceDatabaseObjectDetailTab.options)
                    }.pickerStyle(.segmented).accessibilityIdentifier("newTableSections")
                }.disabled(!controller.canEdit(draft))
                if definition.selectedTab == .options {
                    MobileTableOptionsForm(options: $definition.options, choices: definition.editor.schemaChoices)
                        .disabled(!controller.canEdit(draft))
                } else if definition.selectedTab == .indexes {
                    Section("索引") {
                        ForEach(definition.editor.indexes.filter { !$0.isDeleted }) { item in
                            Button {
                                editing = .init(itemID: item.id, epoch: draft.epoch, section: .indexes)
                            } label: {
                                LabeledContent(item.definition.kind == .primary ? "PRIMARY" : item.definition.name,
                                    value: item.definition.columns.map(\.name).joined(separator: ", "))
                            }.contextMenu {
                                Button("删除索引", role: .destructive) { guard controller.canEdit(draft) else { return }; controller.editingContext(draft).delete(item.id) }
                            }
                        }
                        Button("添加索引", systemImage: "plus") {
                            let id = definition.editor.addIndex()
                            editing = .init(itemID: id, epoch: draft.epoch, section: .indexes, added: true)
                        }
                    }.disabled(!controller.canEdit(draft))
                } else {
                    Section("字段") {
                        ForEach(definition.editor.columns.filter { !$0.isDeleted }) { item in
                            Button { editing = .init(itemID: item.id, epoch: draft.epoch, section: .columns) } label: {
                                HStack {
                                    if definition.editor.isPrimaryKey(columnID: item.id) { Image(systemName: "key.fill").accessibilityLabel("主键") }
                                    Text(item.definition.name.isEmpty ? "未命名字段" : item.definition.name)
                                    Spacer()
                                    Text(item.definition.type).foregroundStyle(.secondary)
                                }
                            }.contextMenu {
                                Button("复制字段") { guard controller.canEdit(draft) else { return }; _ = definition.editor.duplicateColumn(id: item.id) }
                                Button("删除字段", role: .destructive) { guard controller.canEdit(draft) else { return }; controller.editingContext(draft).delete(item.id) }
                            }
                        }
                        Button("添加字段", systemImage: "plus") {
                            let id = definition.editor.addColumn(defaultType: definition.schemaEditingDescriptor.defaultColumnType)
                            editing = .init(itemID: id, epoch: draft.epoch, section: .columns, added: true)
                        }
                    }.disabled(!controller.canEdit(draft))
                }
                if draft.needsVerification {
                    Section {
                        Button("已核对服务器，结束此次操作", role: .destructive) { verify = true }
                    } footer: { Text("请先自行核对目标表是否已经创建。此操作不会再次发送建表 SQL。") }
                } else if !draft.hasCompleted {
                    Section { Button("丢弃新表草稿", role: .destructive) { discard = true } }.disabled(controller.isSubmitting)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("新建表").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(draft.hasCompleted ? "完成" : "保留并关闭") { controller.dismiss() }.disabled(controller.isSubmitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("预览 SQL") { preview = .init(plan: draft.plan) }
                        .disabled(!controller.canEdit(draft) || !draft.isValid).accessibilityIdentifier("previewCreateTable")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    ProgressView().controlSize(.small).opacity(controller.isLoadingChoices || controller.isSubmitting ? 1 : 0)
                    Text(draft.message ?? draft.choicesError ?? (controller.canEdit(draft) ? "先定义字段和索引，再预览建表 SQL" : "请切回目标数据库的表页继续操作"))
                        .font(.caption).lineLimit(3)
                    Spacer(minLength: 0)
                    if draft.choicesError != nil, controller.canEdit(draft) {
                        Button("重试选项") { controller.loadChoices(draft) }
                    }
                }.padding(.horizontal, 16).frame(height: 60).background(.background)
            }
            .sheet(item: $editing) { selection in
                if selection.section == .columns {
                    MobileSchemaColumnEditor(context: controller.editingContext(draft), selection: selection) { editing = nil }
                } else {
                    MobileSchemaIndexEditor(context: controller.editingContext(draft), selection: selection) { editing = nil }
                }
            }
            .sheet(item: $preview) { preview in
                MobileNewTableConfirmation(controller: controller, draft: draft, plan: preview.plan)
            }
            .alert("丢弃新表草稿？", isPresented: $discard) {
                Button("取消", role: .cancel) {}
                Button("丢弃", role: .destructive) { controller.discard(draft) }
            } message: { Text("未提交的字段、索引和表选项将被清除。") }
            .alert("确认已核对服务器？", isPresented: $verify) {
                Button("取消", role: .cancel) {}
                Button("结束此次操作", role: .destructive) { controller.acknowledgeVerification(draft) }
            } message: { Text("不会重复执行建表 SQL。请在服务器核对真实结果后再确认。") }
            .task { await controller.loadChoices(draft)?.value }
            .onDisappear { controller.cancelRead() }
            .interactiveDismissDisabled(controller.isSubmitting)
        }
    }
}

struct MobileNewTableConfirmation: View {
    let controller: MobileNewTableController
    @Bindable var draft: MobileNewTableDraft
    let plan: WorkspaceDatabaseSchemaExecutionPlan
    @Environment(\.dismiss) private var dismiss
    @State private var unlock = false
    var body: some View {
        NavigationStack {
            Form {
                Section("将执行以下 SQL") {
                    Text(plan.statements.map(\.sql).joined(separator: "\n\n"))
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                Section {
                    Label(controller.safetyLock.isEnabled ? "安全锁已开启" : "安全锁已停用", systemImage: controller.safetyLock.isEnabled ? "lock" : "lock.open")
                    Text(draft.message ?? "MySQL 建表会自动提交，不能通过取消撤销。失败或结果不明时不会自动重放。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("确认新建表").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() }.disabled(controller.isSubmitting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(controller.isSubmitting ? "正在创建…" : "创建") {
                        if controller.safetyLock.isEnabled { unlock = true } else { controller.submit(draft, plan: plan) }
                    }.disabled(!controller.canEdit(draft) || draft.plan != plan).accessibilityIdentifier("confirmCreateTable")
                }
            }
            .alert("停用安全锁并创建表？", isPresented: $unlock) {
                Button("取消", role: .cancel) {}
                Button("允许更改并创建", role: .destructive) { controller.safetyLock.disable(); controller.submit(draft, plan: plan) }
            } message: { Text("将执行预览中的建表 SQL。此工作区的安全锁会保持停用，直到重新启用或进入后台。") }
            .interactiveDismissDisabled(controller.isSubmitting)
        }
    }
}
