import SwiftUI

/// Uses the ordinary table's draft grid, including default/NULL menus and
/// stable row IDs. Staging never writes to the database from this sheet.
struct WorkspaceQueryResultInsertSheet: View {
    let stage: @MainActor (WorkspaceDatabaseDataRowInsertEditorState) throws -> Void
    private let page: WorkspaceDatabaseDataPage
    private let request: WorkspaceDatabaseDataRowInsertRequest?
    @Environment(\.dismiss) private var dismiss
    @State private var editor: WorkspaceDatabaseDataRowInsertEditorState
    @State private var selectedRows = IndexSet(integer: 0)
    @State private var preferences = ApplicationPreferences.shared
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var errorMessage: String?

    init(
        editor: WorkspaceDatabaseDataRowInsertEditorState,
        stage: @escaping @MainActor (WorkspaceDatabaseDataRowInsertEditorState) throws -> Void
    ) {
        self.stage = stage
        request = editor.request
        _editor = State(initialValue: editor)
        page = WorkspaceDatabaseDataPage(
            columns: (editor.request?.columns ?? []).enumerated().map {
                WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element.id, type: $0.element.column.type)
            },
            rows: [], offset: 0, limit: WorkspaceDatabaseDataPage.defaultLimit, hasNextPage: false
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.current.text("新增行", "Add Rows"))
                .font(.headline)
            Text(editor.request?.selection.objectName ?? "")
                .foregroundStyle(.secondary).textSelection(.enabled)

            WorkspaceDatabaseDataTable(
                page: page, isFetching: false,
                usesAlternatingRows: false,
                nullDisplayText: preferences.tableNullDisplayStyle.displayText,
                emptyStringDisplayText: preferences.tableEmptyStringDisplayStyle.displayText,
                copyIncludesColumnNames: preferences.copyIncludesColumnNames,
                cellFont: preferences.dataGridFont(),
                exportController: exportController, searchController: searchController,
                exportAllRowsProvider: nil, exportFileName: "",
                sortData: { _ in }, prepareCellEdit: nil, prepareCellEditAsync: nil,
                updateCellEdit: { _, _ in },
                databaseColumns: editor.request?.columns.map(\.column) ?? [],
                pendingLoadedUpdates: [], rowInsertEditor: editor,
                updateRowInsertDraft: { rowID, columnName, draft in
                    editor.update(rowID: rowID, columnName: columnName, draft: draft)
                },
                submitRowInsert: stageDrafts, cancelRowInsert: { dismiss() },
                pendingDeleteRowIndexes: [], selectedRowIndexes: selectedRows,
                rowActionKind: .tableRow, addRow: appendRow, duplicateRow: nil,
                deleteRows: removeRows, pasteRows: nil,
                selectRowsForActions: { selectedRows = $0 }
            )
            .frame(minHeight: 220)

            Text(AppCopy.current.text(
                "双击填写字段，右键可设置 NULL 或默认值。未填写字段由服务器处理，生成列不参与新增。暂存后可预览 SQL，再与其他更改一起提交；提交后重新运行查询查看结果。",
                "Double-click to edit; right-click for NULL or defaults. Unfilled fields use server defaults; generated columns are omitted. Stage rows to preview SQL and commit with other changes, then run the query again to see the result."
            ))
            .font(.callout).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button(AppCopy.current.text("再新增一行", "Add Another Row"), systemImage: "plus", action: appendRow)
                Button(AppCopy.current.text("移除选中行", "Remove Selected Rows"), systemImage: "trash") {
                    removeRows(selectedRows)
                }
                .disabled(selectedRows.isEmpty)
                Spacer()
                Button(AppCopy.current.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppCopy.current.text("暂存", "Stage"), action: stageDrafts)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 800, minHeight: 400, idealHeight: 480)
        .background(Color(nsColor: .queryCraftCanvas))
        .accessibilityIdentifier("queryResultInsertSheet")
    }

    private func appendRow() {
        if editor.isPresented {
            editor.appendRow()
        } else if let request {
            editor.present(request)
        }
        selectedRows = IndexSet(integer: editor.rowCount - 1)
    }

    private func removeRows(_ indexes: IndexSet) {
        let ids = indexes.compactMap { editor.rowID(at: $0) }
        ids.forEach { editor.removeRow(id: $0) }
        selectedRows = []
    }

    private func stageDrafts() {
        // End the native inline editor before capturing the draft snapshot.
        NSApp.keyWindow?.makeFirstResponder(nil)
        do {
            try stage(editor)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
