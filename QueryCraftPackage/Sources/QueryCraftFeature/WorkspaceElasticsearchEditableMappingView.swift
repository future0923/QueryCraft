import AppKit
import SwiftUI

struct WorkspaceElasticsearchEditableMappingView: View {
    @Bindable var editor: WorkspaceElasticsearchMappingEditor
    let workspace: WorkspaceModel
    let resource: WorkspaceMappingTarget
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var rowInsertEditor = WorkspaceDatabaseDataRowInsertEditorState()
    @State private var preferences = ApplicationPreferences.shared
    @State private var showsReloadConfirmation = false

    private var page: WorkspaceDatabaseDataPage { editor.presentation.page }

    var body: some View {
        VStack(spacing: 0) {
            if resource.kind == .elasticsearchAlias {
                HStack {
                    Text(AppCopy.current.text("修改目标", "Edit Target"))
                    Picker(AppCopy.current.text("实际索引", "Concrete Index"), selection: $editor.aliasTarget) {
                        Text(AppCopy.current.text("选择实际索引…", "Choose an index...")).tag("")
                        ForEach(editor.aliasTargets, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().disabled(editor.hasChanges || editor.isCommitting)
                    Button(AppCopy.current.text("加载目标", "Load Target")) {
                        editor.load(target: .init(resource: editor.aliasTarget, kind: .elasticsearchIndex), workspace: workspace)
                    }.disabled(editor.aliasTarget.isEmpty || editor.hasChanges || editor.isCommitting)
                }.padding(8)
            } else if resource.kind == .elasticsearchDataStream {
                Text(AppCopy.current.text("修改 Data Stream \(resource.resource) 的全部 Mapping；索引模板不会同步修改。", "Updates Mapping for the entire Data Stream \(resource.resource); index templates are not updated."))
                    .font(.callout).foregroundStyle(.secondary).padding(8)
            }
            WorkspaceDatabaseDataTable(
                page: page, isFetching: editor.isLoading || editor.isCommitting,
                usesAlternatingRows: preferences.usesAlternatingTableRows,
                nullDisplayText: preferences.tableNullDisplayStyle.displayText,
                emptyStringDisplayText: preferences.tableEmptyStringDisplayStyle.displayText,
                copyIncludesColumnNames: preferences.copyIncludesColumnNames, cellFont: preferences.dataGridFont(),
                exportController: exportController, searchController: searchController,
                exportAllRowsProvider: nil, exportFileName: "mapping", sortData: { _ in },
                prepareCellEdit: prepareEdit, prepareCellEditAsync: nil, updateCellEdit: updateEdit,
                databaseColumns: [], pendingLoadedUpdates: [], rowInsertEditor: rowInsertEditor,
                updateRowInsertDraft: { _, _, _ in }, submitRowInsert: {}, cancelRowInsert: {},
                pendingDeleteRowIndexes: [], selectedRowIndexes: selectionIndexes,
                rowActionKind: .tableRow, addRow: add, duplicateRow: nil,
                deleteRows: { indexes in
                    for index in indexes.reversed() where editor.rows.indices.contains(index) { editor.removeDraft(editor.rows[index].id, workspace: workspace) }
                }, pasteRows: nil,
                selectRowsForActions: { indexes in editor.selectedID = indexes.first.flatMap { editor.rows.indices.contains($0) ? editor.rows[$0].id : nil } },
                mappingActions: WorkspaceMappingGridActions(changedColumns: changedColumns, canEdit: canEdit,
                    menuItems: menuItems, cellOptions: cellOptions, cellControls: cellControls, toggleIndexed: toggleIndexed)
            )
            HStack {
                Text(editor.errorMessage ?? "").lineLimit(1).help(editor.errorMessage ?? "").textSelection(.enabled)
                Spacer()
                if editor.isBlocked {
                    Button(AppCopy.current.text("重新加载服务器版本", "Reload Server Version")) {
                        showsReloadConfirmation = true
                    }
                }
            }.font(.callout).padding(.horizontal, 8).frame(height: 30)
            WorkspaceDatabaseDataProgressBar(isActive: editor.isLoading || editor.isCommitting)
        }
        .task(id: workspace.elasticsearchMutationRevision) {
            if !editor.hasChanges, !editor.isCommitting {
                editor.load(target: editor.snapshot?.target ?? resource, workspace: workspace)
            } else { editor.resumePreparation(workspace: workspace) }
        }
        .alert(AppCopy.current.text("放弃草稿并重新加载？", "Discard Draft and Reload?"), isPresented: $showsReloadConfirmation) {
            Button(AppCopy.current.text("保留草稿", "Keep Draft"), role: .cancel) {}
            Button(AppCopy.current.text("放弃并重新加载", "Discard and Reload"), role: .destructive) {
                editor.discard(); editor.load(target: editor.snapshot?.target ?? resource, workspace: workspace)
            }
        } message: { Text(AppCopy.current.text("本地 Mapping 更改会被服务器状态替换。", "Local Mapping changes will be replaced with server state.")) }
        .alert(AppCopy.current.text("Mapping 已被其他操作修改", "Mapping Changed Externally"), isPresented: $editor.showsConflictConfirmation) {
            Button(AppCopy.current.text("放弃并重新加载", "Discard and Reload"), role: .destructive) {
                editor.discard(); editor.load(target: editor.snapshot?.target ?? resource, workspace: workspace)
            }
            Button(AppCopy.current.text("保留草稿", "Keep Draft"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(AppCopy.current.text(
                "服务器上的目标或相关字段已变化，本次提交已停止，草稿仍保留。重新加载会放弃本地 Mapping 草稿并读取服务器最新版本。",
                "The target or affected fields changed on the server. This submission was stopped and your draft is retained. Reloading discards your local Mapping draft and reads the latest server version."
            ))
        }
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"), isPresented: $editor.showsUnlockConfirmation) {
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) { editor.cancelUnlock() }
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) { editor.confirmUnlock(workspace: workspace) }
        } message: { Text(AppCopy.current.text("允许编辑 Mapping 和执行写请求。", "Allow Mapping edits and write requests in this workspace.")) }
    }

    private var selectionIndexes: IndexSet {
        editor.rows.firstIndex(where: { $0.id == editor.selectedID }).map { IndexSet(integer: $0) } ?? []
    }
    private var changedColumns: [Int: Set<Int>] {
        editor.presentation.changedColumns
    }
    private func canEdit(_ row: Int, _ column: Int) -> Bool {
        editor.rows.indices.contains(row) && editor.rows[row].isNew && column < 3 && column >= 0
            && (column != 2 || editor.rows[row].editableParameters.contains("index"))
            && !editor.isLoading && !editor.isCommitting && !editor.isBlocked
    }
    private func cellOptions(_ index: Int, _ column: Int) -> [NSMenuItem] {
        guard canEdit(index, column), column > 0 else { return [] }
        let row = editor.rows[index]
        let values = column == 1 ? (row.container == "fields" ? ["text", "keyword"] : WorkspaceMappingCodec.newTypes) : ["", "true", "false"]
        return values.map { value in
            let item = WorkspaceMappingMenuItem(title: value.isEmpty ? AppCopy.current.text("服务器默认", "Server Default") : value) {
                editor.requestEdit(workspace: workspace) {
                    guard !editor.isLoading, !editor.isCommitting, !editor.isBlocked,
                          var current = editor.rows.first(where: { $0.id == row.id }), current.isNew else { return }
                    if column == 1 { current.type = value; current.parameters = [:] }
                    else { current.parameters["index"] = value.isEmpty ? nil : value }
                    editor.update(current, workspace: workspace)
                }
            }
            item.state = (column == 1 ? row.type : row.parameters["index"] ?? "") == value ? .on : .off
            return item
        }
    }
    private func cellControls(_ index: Int) -> [Int: WorkspaceGridInlineControl] {
        guard editor.rows.indices.contains(index) else { return [:] }
        return WorkspaceMappingGridActions.controls(row: editor.rows[index], values: page.row(at: index),
                                                    canEdit: { canEdit(index, $0) })
    }
    private func toggleIndexed(_ index: Int) {
        guard canEdit(index, 2) else { return }
        let id = editor.rows[index].id
        editor.requestEdit(workspace: workspace) {
            guard var row = editor.rows.first(where: { $0.id == id }), row.isNew else { return }
            row.parameters["index"] = WorkspaceMappingGridActions.nextIndexedValue(row.parameters["index"])
            editor.update(row, workspace: workspace)
        }
    }
    private func prepareEdit(_ target: WorkspaceDatabaseDataCellEditTarget) -> WorkspaceDatabaseDataCellInlineEditContext? {
        guard canEdit(target.rowIndex, target.dataColumnIndex), !workspace.safetyLock.isEnabled else { return nil }
        let row = editor.rows[target.rowIndex]
        let text = target.dataColumnIndex == 0 ? row.name : target.dataColumnIndex == 1 ? row.type : row.parameters["index"] ?? ""
        return .init(rowIndex: target.rowIndex, dataColumnIndex: target.dataColumnIndex, columnName: target.column?.name ?? "",
            initialText: text, initialMutation: .value(text), editingLifetime: editor.lifetime, editingRevision: editor.lifetime.revision)
    }
    private func updateEdit(_ context: WorkspaceDatabaseDataCellInlineEditContext, _ mutation: WorkspaceDatabaseInspectorMutation) {
        guard editor.rows.indices.contains(context.rowIndex), case .value(let text) = mutation else { return }
        var row = editor.rows[context.rowIndex]
        if context.dataColumnIndex == 0 { row.name = text }
        else if context.dataColumnIndex == 1 { row.type = text; row.parameters = [:] }
        else { row.parameters["index"] = text }
        editor.update(row, workspace: workspace)
    }
    private func add() { editor.requestEdit(workspace: workspace) { editor.add(workspace: workspace) } }
    private func menuItems(_ index: Int) -> [NSMenuItem] {
        guard editor.rows.indices.contains(index) else { return [] }
        let row = editor.rows[index]
        return [
            WorkspaceMappingMenuItem(title: AppCopy.current.text("新增字段", "Add Field"), enabled: editor.canAddFields, action: add),
            WorkspaceMappingMenuItem(title: AppCopy.current.text("新增子字段", "Add Child Field"), enabled: editor.canAddFields && ["object", "nested"].contains(row.type) && !row.name.isEmpty) {
                editor.requestEdit(workspace: workspace) { editor.add(parent: row, workspace: workspace) }
            },
            WorkspaceMappingMenuItem(title: AppCopy.current.text("新增 multi-field", "Add Multi-field"), enabled: editor.canAddFields && ["text", "keyword"].contains(row.type) && !row.name.isEmpty) {
                editor.requestEdit(workspace: workspace) { editor.add(parent: row, multiField: true, workspace: workspace) }
            },
            WorkspaceMappingMenuItem(title: AppCopy.current.text("移除新增字段", "Remove New Field"), enabled: row.isNew && !editor.isCommitting) { editor.removeDraft(row.id, workspace: workspace) }
        ]
    }
}
