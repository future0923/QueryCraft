import SwiftUI

struct WorkspaceElasticsearchDataFilterConditionRow: View {
    private static let controlHeight: CGFloat = 24

    @State private var valueFocusRequest = 0
    @Binding var condition: WorkspaceDatabaseDataFilterCondition
    let columns: [WorkspaceDatabaseColumn]
    let mappingFields: [WorkspaceDocumentMappingField]
    let focusedField: FocusState<WorkspaceDatabaseDataFilterFocus?>.Binding
    let columnPresentationRequest: Int
    let operatorPresentationRequest: Int
    let columnDismissalRequest: Int
    let operatorDismissalRequest: Int
    let columnPresentationChanged: @MainActor @Sendable (Bool) -> Void
    let operatorPresentationChanged: @MainActor @Sendable (Bool) -> Void
    let add: @MainActor @Sendable () -> Void
    let remove: @MainActor @Sendable () -> Void

    var body: some View {
        GridRow {
            WorkspaceElasticsearchBoolClausePicker(
                selection: $condition.elasticsearchClause
            )
            .focused(focusedField, equals: .elasticsearchClause(condition.id))
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: Self.controlHeight)
            .accessibilityIdentifier("elasticsearchFilterClause")

            WorkspaceGridSearchColumnPicker(
                selectedDataColumnIndex: selectedColumnIndex,
                columns: dataColumns,
                includesAllColumns: false,
                accessibilityTitle: AppCopy.current.text(
                    "筛选字段",
                    "Filter Field"
                ),
                triggerWidth: 132,
                presentationRequest: columnPresentationRequest,
                dismissalRequest: columnDismissalRequest,
                presentationChanged: columnPresentationChanged
            )
            .focused(focusedField, equals: .column(condition.id))
            .frame(height: Self.controlHeight)
            .accessibilityIdentifier("elasticsearchFilterField")

            WorkspaceDatabaseDataFilterOperatorPicker(
                selection: $condition.operation,
                options: availableOperators,
                accessibilityTitle: AppCopy.current.text(
                    "查询类型",
                    "Query Type"
                ),
                presentationRequest: operatorPresentationRequest,
                dismissalRequest: operatorDismissalRequest,
                presentationChanged: operatorPresentationChanged
            )
            .focused(focusedField, equals: .operation(condition.id))
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: Self.controlHeight)
            .accessibilityIdentifier("elasticsearchFilterQueryType")

            WorkspaceDatabaseDataFilterValueEditor(
                condition: $condition,
                menuValues: selectedColumn?.dataFilterMenuValues(
                    for: condition.columnKind
                ) ?? [],
                focusedField: focusedField,
                valueFocusRequest: valueFocusRequest
            )
            .frame(maxWidth: .infinity)
            .frame(height: Self.controlHeight)
            .accessibilityIdentifier("elasticsearchFilterValue")

            WorkspaceInlineIconButton(
                systemImageName: "minus",
                title: AppCopy.current.text("移除条件", "Remove Condition"),
                action: remove
            )

            WorkspaceInlineIconButton(
                systemImageName: "plus",
                title: AppCopy.current.text("添加条件", "Add Condition"),
                action: add
            )
        }
        .controlSize(.regular)
        .frame(height: Self.controlHeight)
        .onChange(of: condition.operation) { _, operation in
            if !operation.requiresValue {
                condition.value = ""
                condition.secondValue = ""
                return
            }
            focusedField.wrappedValue = .value(condition.id)
            valueFocusRequest &+= 1
        }
    }

    private var selectedColumn: WorkspaceDatabaseColumn? {
        columns.first { $0.name == condition.columnName }
    }

    private var dataColumns: [WorkspaceDatabaseDataColumn] {
        columns.enumerated().map { index, column in
            WorkspaceDatabaseDataColumn(id: index, name: column.name)
        }
    }

    private var selectedColumnIndex: Binding<Int?> {
        Binding(
            get: {
                columns.firstIndex { $0.name == condition.columnName }
            },
            set: { columnIndex in
                guard let columnIndex, columns.indices.contains(columnIndex) else {
                    return
                }
                updateColumn(columns[columnIndex])
            }
        )
    }

    private var availableOperators: [WorkspaceDatabaseDataFilterOperator] {
        WorkspaceDatabaseDataFilterOperator.available(for: condition.columnKind)
    }

    private func updateColumn(_ selectedColumn: WorkspaceDatabaseColumn) {
        let kind = mappingFields.first { $0.path == selectedColumn.name }?.dataFilterKind
            ?? selectedColumn.dataFilterKind
        condition.selectElasticsearchField(name: selectedColumn.name, kind: kind)
    }
}
