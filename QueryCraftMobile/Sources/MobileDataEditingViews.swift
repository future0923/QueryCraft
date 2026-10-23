import SwiftUI
import QueryCraftMobileCore

struct MobileCellEditView: View {
    let request: WorkspaceDatabaseDataCellEditRequest
    @Bindable var changes: MobileTableChanges
    let deleteRow: () throws -> Void
    let validateContext: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var mode: WorkspaceDatabaseDataRowInsertMode
    @State private var message: String?
    @State private var showsPending = false
    @FocusState private var focused: Bool
    init(request: WorkspaceDatabaseDataCellEditRequest, changes: MobileTableChanges,
         validateContext: @escaping () throws -> Void = {}, deleteRow: @escaping () throws -> Void) {
        self.request = request; self.changes = changes; self.deleteRow = deleteRow
        self.validateContext = validateContext
        _text = State(initialValue: request.initialText)
        _mode = State(initialValue: changes.usesDefault(request) ? .useDefault : (request.initiallyUsesNull ? .null : .value))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("表", value: request.selection.objectName)
                    LabeledContent("字段", value: request.column.name)
                    LabeledContent("类型", value: request.column.type)
                    Picker("值", selection: $mode) {
                        Text("文本").tag(WorkspaceDatabaseDataRowInsertMode.value)
                        if request.column.isNullable { Text("NULL").tag(WorkspaceDatabaseDataRowInsertMode.null) }
                        if request.column.defaultValue != nil || request.column.extra.localizedCaseInsensitiveContains("default_generated") {
                            Text("默认值").tag(WorkspaceDatabaseDataRowInsertMode.useDefault)
                        }
                    }
                    if mode == .value {
                        LabeledContent("内容") {
                            MobileDataValueInput(text: $text) { focused = false }
                                .accessibilityIdentifier("cellEditValue")
                        }
                    }
                } footer: { Text("修改先暂存，统一提交后才写入数据库。") }
                Section {
                    Button("暂存删除此行", role: .destructive) { perform { try deleteRow() } }
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled().scrollDismissesKeyboard(.immediately)
            .navigationTitle("编辑单元格").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if changes.hasChanges {
                        Button("待提交改动", systemImage: "square.and.pencil") { showsPending = true }
                            .accessibilityIdentifier("cellPendingChanges")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("暂存") { perform { try changes.stage(request, text: text, mode: mode) } }
                        .disabled(changes.isSubmitting).accessibilityIdentifier("stageCellEdit")
                }
            }
        }.sheet(isPresented: $showsPending) { MobilePendingChangesView(changes: changes) }
            .accessibilityIdentifier("cellEditSheet")
    }
    private func perform(_ action: () throws -> Void) {
        do { try validateContext(); try action(); focused = false; dismiss() } catch { message = error.localizedDescription }
    }
}

struct MobileInsertView: View {
    @Bindable var draft: MobileInsertDraft
    let changes: MobileTableChanges
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @FocusState private var focused: String?
    var body: some View {
        NavigationStack {
            Form {
                ForEach(draft.request.columns) { column in
                    let binding = Binding(get: { draft.drafts[column.id] ?? column.initialDraft },
                        set: { draft.set($0, column: column.id) })
                    Section {
                        Picker("值", selection: binding.mode) {
                            Text("未填写").tag(WorkspaceDatabaseDataRowInsertMode.unfilled)
                            Text("文本").tag(WorkspaceDatabaseDataRowInsertMode.value)
                            if column.column.isNullable { Text("NULL").tag(WorkspaceDatabaseDataRowInsertMode.null) }
                            if column.canUseDefault { Text("默认值").tag(WorkspaceDatabaseDataRowInsertMode.useDefault) }
                        }
                        if binding.wrappedValue.mode == .value {
                            MobileDataValueInput(text: binding.text) { focused = nil }
                        }
                    } header: { Text(column.id + " · " + column.column.type) }
                }
                Section { Text("未填写及默认值字段由服务器处理；生成列不参与新增。").foregroundStyle(.secondary) }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }
            .onSubmit { focused = nil }.scrollDismissesKeyboard(.immediately)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("新增行 · " + changes.object.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("暂存") {
                    do { try changes.stage(draft); focused = nil; dismiss() } catch { message = error.localizedDescription }
                }.disabled(changes.isSubmitting).accessibilityIdentifier("stageInsert") }
            }
        }.accessibilityIdentifier("insertRowSheet")
    }
}

struct MobilePendingChangesView: View {
    @Bindable var changes: MobileTableChanges
    @Environment(\.dismiss) private var dismiss
    @State private var showsUnlock = false
    @State private var editingInsert: MobileInsertDraft?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("表", value: changes.object.name)
                    LabeledContent("待提交", value: "\(changes.changeCount) 行")
                    Toggle("安全锁", isOn: Binding(get: { changes.safetyLock.isEnabled }, set: {
                        if $0 { changes.safetyLock.enable() } else { changes.safetyLock.disable() }
                    }))
                }
                if !changes.inserts.isEmpty {
                    Section("暂存新增行") {
                        ForEach(changes.inserts) { insert in
                            Button {
                                editingInsert = try? changes.editInsert(insert)
                            } label: {
                                HStack {
                                    Text("新增行")
                                    Spacer()
                                    Text(insert.value.values.map { $0.columnName }.prefix(3).joined(separator: ", "))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }.contextMenu {
                                Button("撤销此条新增", role: .destructive) { changes.removeInsert(insert.id) }
                            }.disabled(changes.isSubmitting || changes.needsVerification)
                        }
                    }
                }
                Section("SQL 预览") {
                    let sql = (try? changes.previewSQL()) ?? "无法生成 SQL 预览"
                    Text(sql.isEmpty ? "暂无待提交改动" : WorkspaceDatabaseDataCell.boundedPreview(sql, maximumCharacterCount: 16_384))
                        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    if sql.count > 16_384 { ShareLink("完整 SQL 预览", item: sql) }
                }
                Section {
                    HStack {
                        ProgressView().opacity(changes.isSubmitting ? 1 : 0).accessibilityHidden(!changes.isSubmitting)
                        Text(changes.isSubmitting ? "正在提交…" : (changes.hasChanges ? "尚未写入数据库" : "没有待提交改动"))
                            .foregroundStyle(.secondary)
                    }.frame(height: 24)
                    if let message = changes.message { Text(message).foregroundStyle(.red) }
                    Button("提交全部改动", systemImage: "checkmark") {
                        if changes.safetyLock.isEnabled { showsUnlock = true } else { changes.submit() }
                    }.disabled(!changes.canSubmit).accessibilityIdentifier("submitDataChanges")
                    Button(changes.needsVerification ? (changes.isQueryResult ? "丢弃草稿，重新查询核对" : "丢弃草稿并刷新核对") : "撤销全部暂存", role: .destructive) { changes.discard() }
                        .disabled(!changes.hasChanges || changes.isSubmitting)
                } footer: { Text("按主键定位原始行，多项修改在同一事务中提交。") }
            }
            .navigationTitle("待提交改动").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .alert("安全锁已启用", isPresented: $showsUnlock) {
                Button("取消", role: .cancel) {}
                Button("解锁并提交") { changes.safetyLock.disable(); changes.submit() }
            } message: { Text("提交上方预览中的改动到 \(changes.object.name)。") }
            .onChange(of: changes.hasChanges) { _, hasChanges in if !hasChanges { dismiss() } }
        }.sheet(item: $editingInsert) { draft in MobileInsertView(draft: draft, changes: changes) }
        .interactiveDismissDisabled(changes.isSubmitting).accessibilityIdentifier("pendingDataChanges")
    }
}
