import AppKit
import SwiftUI

struct WorkspaceDatabaseObjectDetailTabHost: NSViewRepresentable {
    let availableTabs: [WorkspaceDatabaseObjectDetailTab]
    let selectedTab: WorkspaceDatabaseObjectDetailTab
    let detailsState: WorkspaceDatabaseObjectDetailsState
    let indexesState: WorkspaceDatabaseIndexesState
    let dataState: WorkspaceDatabaseDataState
    let retry: () -> Void
    let sortData: (WorkspaceDatabaseDataSort) -> Void
    let appliedDataFilter: WorkspaceDatabaseDataFilter
    let dataFilterEditor: WorkspaceDatabaseDataFilterEditor
    let isDataFilterPresented: Bool
    let detailsStateForDataFilter: WorkspaceDatabaseObjectDetailsState
    let editDataFilter: () -> Void
    let clearDataFilter: () -> Void
    let closeDataFilter: @MainActor @Sendable () -> Void
    let applyDataFilter: () -> Void
    let retryDataFilterDetails: () -> Void
    let exportAllRowsProvider: WorkspaceDataExportAllRowsProvider?
    let exportFileName: String
    let exportController: WorkspaceDataExportController
    let searchController: WorkspaceGridSearchController
    let prepareCellEdit: ((WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    let prepareCellEditAsync: ((WorkspaceDatabaseDataCellEditTarget) async ->
        WorkspaceDatabaseDataCellInlineEditContext?)?
    let updateCellEdit: @MainActor (
        WorkspaceDatabaseDataCellInlineEditContext,
        WorkspaceDatabaseInspectorMutation
    ) -> Void
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
    let selectedDataRowIndexes: IndexSet
    let rowActionKind: WorkspaceDatabaseDataRowActionKind
    let addRow: (@MainActor () -> Void)?
    let duplicateRow: (@MainActor (Int) -> Void)?
    let deleteRows: (@MainActor (IndexSet) -> Void)?
    let pasteRows: WorkspaceGridPasteRowsAction?
    let selectRowsForActions: @MainActor (IndexSet) -> Void
    let canEditSchema: Bool
    let schemaEditingDescriptor: WorkspaceDatabaseSchemaEditingDescriptor
    let schemaEditor: WorkspaceDatabaseSchemaEditorState
    @Binding var tableOptions: WorkspaceDatabaseTableOptions
    @Binding var selectedSchemaColumnID: UUID?
    @Binding var selectedSchemaIndexID: UUID?
    let addSchemaColumn: @MainActor () -> Void
    let duplicateSchemaColumn: @MainActor (UUID) -> Void
    let updateSchemaColumn: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> Void
    let setSchemaColumnPrimaryKey: @MainActor (UUID, Bool) -> Void
    let deleteSchemaColumn: @MainActor (UUID) -> Void
    let addSchemaIndex: @MainActor () -> Void
    let duplicateSchemaIndex: @MainActor (UUID) -> Void
    let updateSchemaIndex: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) -> Void
    let deleteSchemaIndex: @MainActor (UUID) -> Void

    func makeCoordinator() -> WorkspaceDatabaseObjectDetailTabHostCoordinator {
        WorkspaceDatabaseObjectDetailTabHostCoordinator()
    }

    func makeNSView(context: Context) -> NSTabView {
        let tabView = NSTabView()
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false

        for tab in availableTabs {
            context.coordinator.install(root: makeRoot(for: tab), in: tabView)
        }
        context.coordinator.select(selectedTab, in: tabView)
        return tabView
    }

    func updateNSView(_ tabView: NSTabView, context: Context) {
        // Select first so a tab click is not delayed by unrelated content updates.
        context.coordinator.select(selectedTab, in: tabView)

        for tab in availableTabs {
            let root = makeRoot(for: tab)
            context.coordinator.install(root: root, in: tabView)
            context.coordinator.update(root: root)
        }
    }

    private func makeRoot(
        for tab: WorkspaceDatabaseObjectDetailTab
    ) -> WorkspaceDatabaseObjectDetailTabRoot {
        WorkspaceDatabaseObjectDetailTabRoot(
            tab: tab,
            detailsState: detailsState,
            indexesState: indexesState,
            dataState: dataState,
            retry: retry,
            sortData: sortData,
            appliedDataFilter: appliedDataFilter,
            dataFilterEditor: dataFilterEditor,
            isDataFilterPresented: isDataFilterPresented,
            detailsStateForDataFilter: detailsStateForDataFilter,
            editDataFilter: editDataFilter,
            clearDataFilter: clearDataFilter,
            closeDataFilter: closeDataFilter,
            applyDataFilter: applyDataFilter,
            retryDataFilterDetails: retryDataFilterDetails,
            exportAllRowsProvider: exportAllRowsProvider,
            exportFileName: exportFileName,
            exportController: exportController,
            searchController: searchController,
            prepareCellEdit: prepareCellEdit,
            prepareCellEditAsync: prepareCellEditAsync,
            updateCellEdit: updateCellEdit,
            pendingLoadedUpdates: pendingLoadedUpdates,
            rowInsertEditor: rowInsertEditor,
            updateRowInsertDraft: updateRowInsertDraft,
            submitRowInsert: submitRowInsert,
            cancelRowInsert: cancelRowInsert,
            pendingDeleteRowIndexes: pendingDeleteRowIndexes,
            selectedDataRowIndexes: selectedDataRowIndexes,
            rowActionKind: rowActionKind,
            addRow: addRow,
            duplicateRow: duplicateRow,
            deleteRows: deleteRows,
            pasteRows: pasteRows,
            selectRowsForActions: selectRowsForActions,
            canEditSchema: canEditSchema,
            schemaEditingDescriptor: schemaEditingDescriptor,
            schemaEditor: schemaEditor,
            tableOptions: $tableOptions,
            selectedSchemaColumnID: $selectedSchemaColumnID,
            selectedSchemaIndexID: $selectedSchemaIndexID,
            addSchemaColumn: addSchemaColumn,
            duplicateSchemaColumn: duplicateSchemaColumn,
            updateSchemaColumn: updateSchemaColumn,
            setSchemaColumnPrimaryKey: setSchemaColumnPrimaryKey,
            deleteSchemaColumn: deleteSchemaColumn,
            addSchemaIndex: addSchemaIndex,
            duplicateSchemaIndex: duplicateSchemaIndex,
            updateSchemaIndex: updateSchemaIndex,
            deleteSchemaIndex: deleteSchemaIndex
        )
    }
}
