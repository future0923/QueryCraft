import SwiftUI
import QueryCraftMobileCore

struct MobileElasticsearchFilterView: View {
    @Bindable var model: MobileElasticsearchWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var filter: WorkspaceDatabaseDataFilter
    private var fields: [WorkspaceDocumentMappingField] { (model.mapping?.fieldCapabilities ?? []).filter { $0.isSearchable && !$0.hasTypeConflict && WorkspaceDatabaseDataFilterColumnKind(elasticsearchType: $0.type, hasKeywordSubfield: $0.keywordSubfieldPath != nil) != nil } }
    init(model: MobileElasticsearchWorkspace) { self.model = model; _filter = State(initialValue: model.filter) }
    var body: some View {
        NavigationStack {
            Form {
                ForEach($filter.conditions) { $condition in
                    Section {
                        Picker("字段", selection: Binding(get: { condition.columnName }, set: { name in
                            guard let field = fields.first(where: { $0.path == name }), let kind = WorkspaceDatabaseDataFilterColumnKind(elasticsearchType: field.type, hasKeywordSubfield: field.keywordSubfieldPath != nil) else { return }
                            condition = .init(id: condition.id, columnName: name, columnKind: kind, elasticsearchClause: condition.elasticsearchClause, operation: WorkspaceDatabaseDataFilterOperator.available(for: kind).first ?? .exists)
                        })) { ForEach(fields) { field in Text(field.path + " · " + field.type).tag(field.path) } }
                        Picker("Bool 子句", selection: $condition.elasticsearchClause) { ForEach(WorkspaceElasticsearchBoolClause.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("运算符", selection: $condition.operation) { ForEach(WorkspaceDatabaseDataFilterOperator.available(for: condition.columnKind), id: \.self) { Text($0.title).tag($0) } }
                        if condition.operation.requiresValue { TextField("值", text: $condition.value).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        if condition.operation.requiresSecondValue { TextField("结束值", text: $condition.secondValue).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        Button("移除条件", role: .destructive) { filter.conditions.removeAll { $0.id == condition.id } }
                    }
                }
                Section {
                    Button("添加条件") {
                        guard let field = fields.first, let kind = WorkspaceDatabaseDataFilterColumnKind(elasticsearchType: field.type, hasKeywordSubfield: field.keywordSubfieldPath != nil) else { return }
                        filter.conditions.append(.init(columnName: field.path, columnKind: kind, operation: WorkspaceDatabaseDataFilterOperator.available(for: kind).first ?? .exists))
                    }.disabled(fields.isEmpty)
                    Button("清空条件", role: .destructive) { filter = .empty }
                    Text("筛选整个索引、Alias 或 Data Stream。使用真实 Mapping / Field Caps，类型冲突字段不可选；text 的精确匹配沿桌面规则使用 keyword 子字段。").font(.caption)
                }
            }.scrollDismissesKeyboard(.interactively)
            .navigationTitle("服务端筛选").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("应用") { model.apply(filter: filter); dismiss() }.disabled(!filter.isValid || !model.canNavigate) } }
        }
    }
}
