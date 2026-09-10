import AppKit
import SwiftUI

struct WorkspaceDatabaseDataTable: NSViewRepresentable {
    let page: WorkspaceDatabaseDataPage
    let isFetching: Bool
    let usesAlternatingRows: Bool
    let nullDisplayText: String
    let emptyStringDisplayText: String
    let copyIncludesColumnNames: Bool
    let cellFont: NSFont
    let exportController: WorkspaceDataExportController
    let searchController: WorkspaceGridSearchController
    let exportAllRowsProvider: WorkspaceDataExportAllRowsProvider?
    let exportFileName: String
    let sortData: (WorkspaceDatabaseDataSort) -> Void
    let prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    let prepareCellEditAsync: ((WorkspaceDatabaseDataCellEditTarget) async ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    let updateCellEdit: @MainActor (
        WorkspaceDatabaseDataCellInlineEditContext,
        WorkspaceDatabaseInspectorMutation
    ) -> Void
    let databaseColumns: [WorkspaceDatabaseColumn]
    let pendingLoadedUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    let rowInsertEditor: WorkspaceDatabaseDataRowInsertEditorState
    let updateRowInsertDraft: @MainActor (
        UUID,
        String,
        WorkspaceDatabaseDataRowInsertDraft
    ) -> Void
    let submitRowInsert: @MainActor () -> Void
    let cancelRowInsert: @MainActor () -> Void
    let pendingDeleteRowIndexes: IndexSet
    let selectedRowIndexes: IndexSet
    let rowActionKind: WorkspaceDatabaseDataRowActionKind
    let addRow: (@MainActor () -> Void)?
    let duplicateRow: (@MainActor (Int) -> Void)?
    let deleteRows: (@MainActor (IndexSet) -> Void)?
    let pasteRows: WorkspaceGridPasteRowsAction?
    let selectRowsForActions: @MainActor (IndexSet) -> Void
    var mappingActions: WorkspaceMappingGridActions? = nil

    func makeCoordinator() -> WorkspaceDatabaseDataTableCoordinator {
        WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: isFetching,
            usesAlternatingRows: usesAlternatingRows,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            copyIncludesColumnNames: copyIncludesColumnNames,
            cellFont: cellFont,
            exportController: exportController,
            searchController: searchController,
            exportAllRowsProvider: exportAllRowsProvider,
            exportFileName: exportFileName,
            sortData: sortData,
            prepareCellEdit: prepareCellEdit,
            prepareCellEditAsync: prepareCellEditAsync,
            updateCellEdit: updateCellEdit,
            databaseColumns: databaseColumns,
            pendingLoadedUpdates: pendingLoadedUpdates,
            rowInsertEditor: rowInsertEditor,
            updateRowInsertDraft: updateRowInsertDraft,
            submitRowInsert: submitRowInsert,
            cancelRowInsert: cancelRowInsert,
            pendingDeleteRowIndexes: pendingDeleteRowIndexes,
            selectedRowIndexes: selectedRowIndexes,
            rowActionKind: rowActionKind,
            addRow: addRow,
            duplicateRow: duplicateRow,
            deleteRows: deleteRows,
            pasteRows: pasteRows,
            selectRowsForActions: selectRowsForActions
        )
    }

    func makeNSView(
        context: Context
    ) -> NSScrollView {
        context.coordinator.mappingActions = mappingActions
        return context.coordinator.makeScrollView()
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.mappingActions = mappingActions
        context.coordinator.update(
            page: page,
            isFetching: isFetching,
            usesAlternatingRows: usesAlternatingRows,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            copyIncludesColumnNames: copyIncludesColumnNames,
            cellFont: cellFont,
            exportAllRowsProvider: exportAllRowsProvider,
            exportFileName: exportFileName,
            sortData: sortData,
            prepareCellEdit: prepareCellEdit,
            prepareCellEditAsync: prepareCellEditAsync,
            updateCellEdit: updateCellEdit,
            databaseColumns: databaseColumns,
            pendingLoadedUpdates: pendingLoadedUpdates,
            rowInsertEditor: rowInsertEditor,
            updateRowInsertDraft: updateRowInsertDraft,
            submitRowInsert: submitRowInsert,
            cancelRowInsert: cancelRowInsert,
            pendingDeleteRowIndexes: pendingDeleteRowIndexes,
            selectedRowIndexes: selectedRowIndexes,
            rowActionKind: rowActionKind,
            addRow: addRow,
            duplicateRow: duplicateRow,
            deleteRows: deleteRows,
            pasteRows: pasteRows,
            selectRowsForActions: selectRowsForActions
        )
    }
}
