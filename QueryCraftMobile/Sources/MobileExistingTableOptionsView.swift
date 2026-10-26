import SwiftUI

/// A one-time editable copy, staged into the same schema draft as fields/indexes.
struct MobileExistingTableOptionsView: View {
    let controller: MobileSchemaController
    let draft: MobileSchemaDraft
    let close: () -> Void
    @State private var epoch: UUID
    @State private var options: WorkspaceDatabaseTableOptions
    init(controller: MobileSchemaController, draft: MobileSchemaDraft, close: @escaping () -> Void) {
        self.controller = controller; self.draft = draft; self.close = close
        _epoch = State(initialValue: draft.epoch)
        _options = State(initialValue: draft.state.tableOptions)
    }
    private var editable: Bool { controller.canEdit(draft) && draft.epoch == epoch && draft.snapshot?.options != nil }
    private var choicesAreValid: Bool {
        guard let original = draft.snapshot?.options else { return false }
        let fields: [KeyPath<WorkspaceDatabaseTableOptions, String>] = [\.engine, \.characterSet, \.collation]
        return fields.allSatisfy { original[keyPath: $0].isEmpty || !options[keyPath: $0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var feedback: String {
        if !editable { return "此编辑上下文已失效，请关闭后使用顶部刷新重新读取。" }
        if !choicesAreValid { return "已有表的引擎、字符集和排序规则不能清空，请填写或选择支持的值。" }
        return "暂存后，在结构页的待提交改动中预览 SQL。更改引擎或行格式可能重建表；字符设置只修改表默认值。"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { LabeledContent("数据库", value: draft.object.database); LabeledContent("表", value: draft.object.name) }
                MobileTableOptionsForm(options: $options, choices: draft.state.schemaChoices, allowsDatabaseDefaults: false)
                    .disabled(!editable)
                Section { MobileFormStatus(message: feedback, isError: !editable || !choicesAreValid) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("表选项").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: close) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("暂存") { guard editable, choicesAreValid else { return }; draft.updateOptions(options); close() }.disabled(!editable || !choicesAreValid)
                        .accessibilityIdentifier("stageTableOptions")
                }
            }

        }
    }
}
