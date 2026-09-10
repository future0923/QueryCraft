import SwiftUI

struct WorkspaceElasticsearchMappingView: View {
    @State private var page: WorkspaceDatabaseDataPage
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var rowInsertEditor = WorkspaceDatabaseDataRowInsertEditorState()
    @State private var selectedRows = IndexSet()
    @State private var preferences = ApplicationPreferences.shared

    init(fields: [WorkspaceDocumentMappingField]) {
        _page = State(initialValue: Self.makePage(fields: fields))
    }

    var body: some View {
        if page.rowCount == 0 {
            ContentUnavailableView(
                AppCopy.current.text("没有 Mapping 字段", "No Mapping Fields"),
                systemImage: "list.bullet.rectangle"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WorkspaceDatabaseDataTable(
                page: page,
                isFetching: false,
                usesAlternatingRows: preferences.usesAlternatingTableRows,
                nullDisplayText: preferences.tableNullDisplayStyle.displayText,
                emptyStringDisplayText:
                    preferences.tableEmptyStringDisplayStyle.displayText,
                copyIncludesColumnNames: preferences.copyIncludesColumnNames,
                cellFont: preferences.dataGridFont(),
                exportController: exportController,
                searchController: searchController,
                exportAllRowsProvider: nil,
                exportFileName: "mapping",
                sortData: { _ in },
                prepareCellEdit: nil,
                prepareCellEditAsync: nil,
                updateCellEdit: { _, _ in },
                databaseColumns: [],
                pendingLoadedUpdates: [],
                rowInsertEditor: rowInsertEditor,
                updateRowInsertDraft: { _, _, _ in },
                submitRowInsert: {},
                cancelRowInsert: {},
                pendingDeleteRowIndexes: [],
                selectedRowIndexes: selectedRows,
                rowActionKind: .tableRow,
                addRow: nil,
                duplicateRow: nil,
                deleteRows: nil,
                pasteRows: nil,
                selectRowsForActions: { selectedRows = $0 }
            )
        }
    }

    private static func makePage(
        fields: [WorkspaceDocumentMappingField]
    ) -> WorkspaceDatabaseDataPage {
        let names = [
            AppCopy.current.text("字段", "Field"),
            AppCopy.current.text("类型", "Type"),
            AppCopy.current.text("已索引", "Indexed"),
            AppCopy.current.text("可搜索", "Searchable"),
            AppCopy.current.text("可聚合", "Aggregatable"),
        ]
        let columns = names.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        let rows = fields.enumerated().map { index, field in
            WorkspaceDatabaseDataRow(
                id: index,
                values: [
                    .text(field.path),
                    .text(field.hasTypeConflict
                        ? AppCopy.current.text(
                            "冲突：\(field.type)",
                            "Conflict: \(field.type)"
                        )
                        : field.type),
                    .text(booleanText(field.isIndexed)),
                    .text(booleanText(field.isSearchable)),
                    .text(booleanText(field.isAggregatable)),
                ]
            )
        }
        return WorkspaceDatabaseDataPage(
            columns: columns,
            rows: rows,
            offset: 0,
            limit: max(rows.count, 1),
            hasNextPage: false
        )
    }

    private static func booleanText(_ value: Bool) -> String {
        value
            ? AppCopy.current.text("是", "Yes")
            : AppCopy.current.text("否", "No")
    }
}
