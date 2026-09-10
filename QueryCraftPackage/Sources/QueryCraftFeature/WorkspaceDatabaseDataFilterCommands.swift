import SwiftUI

public struct WorkspaceDatabaseDataFilterCommands: Commands {
    @FocusedValue(\.workspaceDatabaseDataFilterPresentationActions)
    private var presentationActions

    @FocusedValue(\.workspaceDatabaseDataFilterActions)
    private var actions

    @FocusedValue(\.workspaceDatabaseDataRowActions)
    private var rowActions

    @FocusedValue(\.workspaceDatabaseSchemaRowActions)
    private var schemaRowActions

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(
                AppCopy.current.text("筛选表数据…", "Filter Table Data..."),
                systemImage: "line.3.horizontal.decrease",
                action: togglePresentation
            )
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(presentationActions == nil)

            Divider()

            Button(
                actions != nil
                    ? AppCopy.current.text(
                        "添加筛选条件",
                        "Add Filter Condition"
                    )
                    : schemaRowActions?.kind.addTitle
                        ?? (rowActions?.kind == .elasticsearchDocument
                            ? AppCopy.current.text("新增文档", "Add Document")
                            : AppCopy.current.text("新增行", "Add Row")),
                action: addConditionOrRow
            )
            .keyboardShortcut("i", modifiers: .command)
            .disabled(
                actions == nil
                    ? schemaRowActions?.canAdd != true
                        && rowActions?.canAddRow != true
                    : actions?.canAddCondition != true
            )

            Button(
                schemaRowActions?.kind.duplicateTitle
                    ?? (rowActions?.kind == .elasticsearchDocument
                        ? AppCopy.current.text(
                            "复制为新增文档",
                            "Duplicate as New Document"
                        )
                        : AppCopy.current.text("复制行", "Duplicate Row")),
                action: duplicateRow
            )
            .keyboardShortcut("d", modifiers: .command)
            .disabled(
                actions != nil
                    || (schemaRowActions?.canDuplicate != true
                        && rowActions?.canDuplicateRow != true)
            )

            Button(
                schemaRowActions?.kind.deleteTitle
                    ?? ((rowActions?.selectedRowIndexes.count ?? 0) > 1
                    ? (rowActions?.kind == .elasticsearchDocument
                        ? AppCopy.current.text(
                            "删除 \(rowActions?.selectedRowIndexes.count ?? 0) 篇文档",
                            "Delete \(rowActions?.selectedRowIndexes.count ?? 0) Documents"
                        )
                        : AppCopy.current.text(
                            "删除 \(rowActions?.selectedRowIndexes.count ?? 0) 行",
                            "Delete \(rowActions?.selectedRowIndexes.count ?? 0) Rows"
                        ))
                    : rowActions?.kind == .elasticsearchDocument
                        ? AppCopy.current.text("删除文档", "Delete Document")
                        : AppCopy.current.text("删除行", "Delete Row")),
                action: deleteRow
            )
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(
                actions != nil
                    || (schemaRowActions?.canDelete != true
                        && rowActions?.canDeleteRow != true)
            )

            Button(
                AppCopy.current.text("移除筛选条件", "Remove Filter Condition"),
                action: removeCondition
            )
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(actions?.canRemoveCondition != true)

            Button(
                AppCopy.current.text("全部应用筛选", "Apply All Filters"),
                action: applyAll
            )
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(actions?.canApplyAll != true)

            Divider()

            Button(
                AppCopy.current.text("上一个筛选条件", "Previous Filter Condition"),
                action: moveUp
            )
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(actions?.canNavigateConditions != true)

            Button(
                AppCopy.current.text("下一个筛选条件", "Next Filter Condition"),
                action: moveDown
            )
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(actions?.canNavigateConditions != true)

            Button(
                AppCopy.current.text("打开筛选列", "Open Filter Column"),
                action: openColumnPicker
            )
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(actions?.canEditActiveCondition != true)

            Button(
                AppCopy.current.text("打开筛选运算符", "Open Filter Operator"),
                action: openOperatorPicker
            )
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(actions?.canEditActiveCondition != true)

            Button(
                AppCopy.current.text(
                    "启用或停用筛选条件",
                    "Toggle Filter Condition"
                ),
                action: toggleCondition
            )
            .keyboardShortcut("b", modifiers: .command)
            .disabled(actions?.canToggleCondition != true)

            Button(
                AppCopy.current.text("关闭筛选", "Close Filter"),
                action: close
            )
            .keyboardShortcut(.cancelAction)
            .disabled(actions?.canCloseFilter != true)
        }
    }

    public init() {}

    private func togglePresentation() {
        presentationActions?.toggle()
    }

    private func addConditionOrRow() {
        if let actions {
            actions.addCondition()
        } else if let schemaRowActions {
            schemaRowActions.add()
        } else {
            rowActions?.addRow()
        }
    }

    private func duplicateRow() {
        if let schemaRowActions,
           let selectedID = schemaRowActions.selectedID
        {
            schemaRowActions.duplicate(selectedID)
            return
        }
        guard let row = rowActions?.selectedRowIndex else { return }
        rowActions?.duplicateRow(row)
    }

    private func deleteRow() {
        if let schemaRowActions,
           let selectedID = schemaRowActions.selectedID
        {
            schemaRowActions.delete(selectedID)
            return
        }
        guard let rows = rowActions?.selectedRowIndexes else { return }
        rowActions?.deleteRows(rows)
    }

    private func removeCondition() {
        actions?.removeCondition()
    }

    private func applyAll() {
        actions?.applyAll()
    }

    private func moveUp() {
        actions?.moveUp()
    }

    private func moveDown() {
        actions?.moveDown()
    }

    private func openColumnPicker() {
        actions?.openColumnPicker()
    }

    private func openOperatorPicker() {
        actions?.openOperatorPicker()
    }

    private func toggleCondition() {
        actions?.toggleCondition()
    }

    private func close() {
        actions?.close()
    }
}
