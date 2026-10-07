import AppKit
import SwiftUI

struct WorkspaceKafkaConfigurationGrid: View {
    @Bindable var editor: WorkspaceKafkaTopicConfigurationModel
    let filter: String
    let loading: Bool
    @State private var selectedName: String?
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var rowInsertEditor = WorkspaceDatabaseDataRowInsertEditorState()
    @State private var preferences = ApplicationPreferences.shared
    @State private var pageCache = WorkspaceKafkaConfigurationPageCache()

    private var fields: [WorkspaceKafkaTopicConfigurationModel.Field] {
        editor.fields.filter { filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter) }
    }
    private var changedNames: Set<String> { Set(editor.changes.map(\.id)) }
    private var page: WorkspaceDatabaseDataPage {
        let copy = AppCopy.current
        let columns = [copy.text("配置项", "Property"), copy.text("值", "Value"), copy.text("来源", "Source"), copy.text("状态", "Status")]
            .enumerated().map { WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element) }
        let rows = fields.enumerated().map { index, field in
            WorkspaceDatabaseDataRow(id: index, values: [.text(field.id),
                .text(field.original.isSensitive ? "••••" : field.inheritsDefault && !field.original.isDefault
                      ? copy.text("提交后读取默认值", "Default will be read after commit") : field.value),
                .text(field.inheritsDefault ? copy.text("继承默认值", "Inherited default") : copy.text("Topic 覆盖", "Topic override")),
                .text(field.original.isReadOnly || field.original.isSensitive ? copy.text("只读", "Read-only")
                      : changedNames.contains(field.id) ? copy.text("待提交", "Modified") : "—")])
        }
        return pageCache.page(columns: columns, rows: rows)
    }

    var body: some View {
        WorkspaceDatabaseDataTable(
            page: page, isFetching: loading || editor.isBusy,
            usesAlternatingRows: preferences.usesAlternatingTableRows,
            nullDisplayText: preferences.tableNullDisplayStyle.displayText,
            emptyStringDisplayText: preferences.tableEmptyStringDisplayStyle.displayText,
            copyIncludesColumnNames: preferences.copyIncludesColumnNames,
            formatsTimestamps: false, cellFont: preferences.dataGridFont(),
            exportController: exportController, searchController: searchController,
            exportAllRowsProvider: nil, exportFileName: editor.topic + "-config", sortData: { _ in },
            prepareCellEdit: prepareEdit, prepareCellEditAsync: nil, updateCellEdit: updateEdit,
            databaseColumns: [], pendingLoadedUpdates: [], rowInsertEditor: rowInsertEditor,
            updateRowInsertDraft: { _, _, _ in }, submitRowInsert: {}, cancelRowInsert: {},
            pendingDeleteRowIndexes: [], selectedRowIndexes: fields.firstIndex(where: { $0.id == selectedName }).map { IndexSet(integer: $0) } ?? [],
            rowActionKind: .tableRow, addRow: nil, duplicateRow: nil, deleteRows: nil, pasteRows: nil,
            selectRowsForActions: { indexes in selectedName = indexes.first.flatMap { fields.indices.contains($0) ? fields[$0].id : nil } },
            mappingActions: .init(changedColumns: Dictionary(uniqueKeysWithValues: fields.enumerated().compactMap { index, field in
                changedNames.contains(field.id) ? (index, Set([1, 2])) : nil
            }), canEdit: canEdit, menuItems: menuItems, compactColumns: [],
                rowToolTip: AppCopy.current.text("双击值直接编辑；右键恢复默认值或撤销本项更改。使用顶部工具栏预览、提交或放弃。",
                                                "Double-click a value to edit. Right-click to restore the default or revert a change. Preview, commit or discard from the top toolbar."))
        )
        .accessibilityIdentifier("kafkaConfigurationGrid")
        .onChange(of: filter) { _, _ in editor.lifetime.finish(commit: true) }
        .onDisappear { editor.lifetime.finish(commit: true) }
    }

    private func canEdit(_ row: Int, _ column: Int) -> Bool {
        column == 1 && fields.indices.contains(row) && !fields[row].original.isReadOnly && !fields[row].original.isSensitive
            && !loading && !editor.isBusy && !editor.needsReload
    }
    func prepareEdit(_ target: WorkspaceDatabaseDataCellEditTarget) -> WorkspaceDatabaseDataCellInlineEditContext? {
        guard canEdit(target.rowIndex, target.dataColumnIndex) else { return nil }
        let field = fields[target.rowIndex]
        // Freeze the configuration name; filtering or refreshing must not retarget an edit.
        return .init(rowIndex: target.rowIndex, dataColumnIndex: 1, columnName: field.id,
                     initialText: field.value, initialMutation: field.inheritsDefault ? .useDefault : .value(field.value),
                     editingLifetime: editor.lifetime, editingRevision: editor.lifetime.revision)
    }
    func updateEdit(_ context: WorkspaceDatabaseDataCellInlineEditContext, _ mutation: WorkspaceDatabaseInspectorMutation) {
        guard !loading else { return }
        switch mutation {
        case .value(let value): editor.update(context.columnName, value: value)
        case .useDefault: editor.update(context.columnName, value: context.initialText, inheritsDefault: true)
        case .null: break
        }
    }
    private func menuItems(_ index: Int) -> [NSMenuItem] {
        guard fields.indices.contains(index) else { return [] }
        let field = fields[index]
        let editable = canEdit(index, 1)
        return [
            WorkspaceMappingMenuItem(title: AppCopy.current.text("恢复默认值", "Restore Default"), enabled: editable && !field.inheritsDefault) {
                editor.lifetime.finish(commit: true)
                editor.update(field.id, inheritsDefault: true)
            },
            WorkspaceMappingMenuItem(title: AppCopy.current.text("撤销本项更改", "Revert Change"), enabled: !editor.isBusy && changedNames.contains(field.id)) {
                editor.revert(field.id)
            }
        ]
    }
}

@MainActor
final class WorkspaceKafkaConfigurationPageCache {
    private var cached: WorkspaceDatabaseDataPage?

    func page(columns: [WorkspaceDatabaseDataColumn], rows: [WorkspaceDatabaseDataRow]) -> WorkspaceDatabaseDataPage {
        // Selection and toolbar changes must not reload the native table while
        // its field editor owns focus. Only replace the page when cells change.
        if let cached, cached.columns == columns, cached.rows == rows { return cached }
        let page = WorkspaceDatabaseDataPage(columns: columns, rows: rows, offset: 0,
                                              limit: max(1, rows.count), hasNextPage: false)
        cached = page
        return page
    }
}
