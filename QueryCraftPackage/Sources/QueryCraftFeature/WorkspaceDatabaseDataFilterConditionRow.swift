import SwiftUI

struct WorkspaceDatabaseDataFilterConditionRow: View {
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
        HStack(spacing: 8) {
            Toggle(
                AppCopy.current.text("启用条件", "Enable Condition"),
                isOn: $condition.isEnabled
            )
            .labelsHidden()
            .focused(focusedField, equals: .enabled(condition.id))
            .help(AppCopy.current.text("启用条件", "Enable Condition"))

            WorkspaceGridSearchColumnPicker(
                selectedDataColumnIndex: selectedColumnIndex,
                columns: dataColumns,
                includesAllColumns: false,
                accessibilityTitle: AppCopy.current.text("筛选列", "Filter Column"),
                triggerWidth: 132,
                presentationRequest: columnPresentationRequest,
                dismissalRequest: columnDismissalRequest,
                presentationChanged: columnPresentationChanged
            )
            .focused(focusedField, equals: .column(condition.id))
            .frame(height: Self.controlHeight)
            .disabled(!condition.isEnabled)

            WorkspaceDatabaseDataFilterOperatorPicker(
                selection: $condition.operation,
                options: availableOperators,
                presentationRequest: operatorPresentationRequest,
                dismissalRequest: operatorDismissalRequest,
                presentationChanged: operatorPresentationChanged
            )
            .focused(focusedField, equals: .operation(condition.id))
            .frame(width: operatorWidth, height: Self.controlHeight)
            .disabled(!condition.isEnabled)

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
            .disabled(!condition.isEnabled)

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
            guard let nextFocus = WorkspaceDatabaseDataFilterFocus
                .preferredAfterSelecting(
                    operation,
                    conditionID: condition.id
                )
            else { return }
            focusedField.wrappedValue = nextFocus
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

    private var selectedMappingField: WorkspaceDocumentMappingField? {
        mappingFields.first { $0.path == condition.columnName }
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
                condition.columnName = columns[columnIndex].name
                updateColumn()
            }
        )
    }

    private var availableOperators: [WorkspaceDatabaseDataFilterOperator] {
        WorkspaceDatabaseDataFilterOperator.available(for: condition.columnKind)
    }

    private var operatorWidth: CGFloat {
        switch condition.columnKind {
        case .elasticsearchKeyword, .elasticsearchText,
             .elasticsearchTextWithKeyword, .elasticsearchNumber,
             .elasticsearchDate, .elasticsearchIP,
             .elasticsearchBoolean:
            176
        case .text, .number, .date, .enumeration, .boolean, .binary:
            112
        }
    }

    private func updateColumn() {
        guard let selectedColumn else { return }
        let kind = selectedMappingField?.dataFilterKind
            ?? selectedColumn.dataFilterKind
        condition.columnKind = kind
        let operators = WorkspaceDatabaseDataFilterOperator.available(
            for: kind
        )
        if !operators.contains(condition.operation) {
            condition.operation = operators[0]
        }
        if let firstValue = selectedColumn.dataFilterMenuValues(
            for: kind
        ).first {
            condition.value = firstValue
        } else {
            condition.value = ""
        }
        condition.secondValue = ""
    }
}
