import SwiftUI
import QueryCraftMobileCore

struct MobileTableFilterEditor: View {
    @Bindable var draft: MobileTableFilterDraft
    let apply: @MainActor (WorkspaceDatabaseDataFilter) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedInput: MobileFilterInput?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("匹配方式", selection: $draft.filter.logic) {
                        ForEach(WorkspaceDatabaseDataFilterLogic.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                ForEach($draft.filter.conditions) { $condition in
                    Section {
                        MobileFilterConditionRow(condition: $condition, columns: draft.columns, focusedInput: $focusedInput)
                        Button("移除条件", role: .destructive) { draft.filter.conditions.removeAll { $0.id == condition.id } }
                    }
                }
                Section {
                    Button("添加条件", systemImage: "plus") { draft.addCondition() }
                    Button("清空条件", role: .destructive) { draft.filter = .empty }
                } footer: { Text("在整个表或视图中筛选，结果按页加载。") }
                if let message = draft.message { Section { Text(message).foregroundStyle(.red) } }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("筛选 · " + draft.object.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        do { try apply(draft.filter); dismiss() }
                        catch { draft.message = error.localizedDescription }
                    }.disabled(!draft.canApply).accessibilityIdentifier("applyTableFilter")
                }
            }
        }
        .accessibilityIdentifier("tableFilterEditor")
    }
}

private enum MobileFilterInput: Hashable {
    case value(UUID)
    case secondValue(UUID)
}

private struct MobileFilterConditionRow: View {
    @Binding var condition: WorkspaceDatabaseDataFilterCondition
    let columns: [MobileTableColumn]
    let focusedInput: FocusState<MobileFilterInput?>.Binding
    private var column: MobileTableColumn? { columns.first { $0.name == condition.columnName } }
    private var values: [String] { WorkspaceSQLDataFilterColumn.menuValues(type: column?.type ?? "", kind: condition.columnKind) }
    var body: some View {
        Toggle("启用条件", isOn: $condition.isEnabled)
        Group {
            Picker("字段", selection: Binding(get: { condition.columnName }, set: { selectColumn($0) })) {
                ForEach(columns) { Text($0.name).tag($0.name) }
            }
            Picker("运算符", selection: $condition.operation) {
                ForEach(WorkspaceDatabaseDataFilterOperator.available(for: condition.columnKind), id: \.self) { Text($0.title).tag($0) }
            }
            if condition.operation.requiresValue {
                if !values.isEmpty {
                    Picker("值", selection: $condition.value) {
                        ForEach(values, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    valueField(condition.operation.requiresSecondValue ? "起始值" : "值", text: $condition.value, input: .value(condition.id))
                }
                if condition.operation.requiresSecondValue { valueField("结束值", text: $condition.secondValue, input: .secondValue(condition.id)) }
            }
        }.disabled(!condition.isEnabled).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private func valueField(_ title: String, text: Binding<String>, input: MobileFilterInput) -> some View {
        LabeledContent(title) {
            TextField("请输入", text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(condition.columnKind == .number ? .numbersAndPunctuation : .default)
                .focused(focusedInput, equals: input)
                .submitLabel(.done)
                .onSubmit { focusedInput.wrappedValue = nil }
                .accessibilityLabel(title)
        }
    }
    private func selectColumn(_ name: String) {
        guard let column = columns.first(where: { $0.name == name }) else { return }
        WorkspaceSQLDataFilterColumn.selectColumn(&condition, name: name, type: column.type, kind: .init(mysqlType: column.type))
    }
}
