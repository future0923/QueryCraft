import SwiftUI

struct WorkspaceDatabaseObjectDetailTabRoot: Equatable, View {
    let tab: WorkspaceDatabaseObjectDetailTab
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
    nonisolated let schemaEditor: WorkspaceDatabaseSchemaEditorState
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

    nonisolated static func == (
        lhs: WorkspaceDatabaseObjectDetailTabRoot,
        rhs: WorkspaceDatabaseObjectDetailTabRoot
    ) -> Bool {
        guard lhs.tab == rhs.tab else { return false }

        switch lhs.tab {
        case .data:
            return lhs.appliedDataFilter == rhs.appliedDataFilter
                && lhs.isDataFilterPresented == rhs.isDataFilterPresented
                && lhs.detailsStateForDataFilter
                    == rhs.detailsStateForDataFilter
                && lhs.rowInsertEditor == rhs.rowInsertEditor
                && lhs.pendingLoadedUpdates == rhs.pendingLoadedUpdates
                && lhs.pendingDeleteRowIndexes == rhs.pendingDeleteRowIndexes
                && lhs.selectedDataRowIndexes == rhs.selectedDataRowIndexes
                && lhs.rowActionKind == rhs.rowActionKind
                && WorkspaceDatabaseDataView.statesRenderEqually(
                    lhs.dataState,
                    rhs.dataState
                )
        case .structure, .options, .ddl:
            guard lhs.detailsState == rhs.detailsState,
                  lhs.canEditSchema == rhs.canEditSchema,
                  lhs.schemaEditingDescriptor == rhs.schemaEditingDescriptor
            else { return false }
            return lhs.schemaEditor == rhs.schemaEditor
        case .indexes:
            guard lhs.indexesState == rhs.indexesState,
                  lhs.canEditSchema == rhs.canEditSchema,
                  lhs.schemaEditingDescriptor == rhs.schemaEditingDescriptor
            else { return false }
            return lhs.schemaEditor == rhs.schemaEditor
        }
    }

    var body: some View {
        switch tab {
        case .data:
            WorkspaceDatabaseDataView(
                state: dataState,
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
                selectRowsForActions: selectRowsForActions
            )
            .equatable()

        case .structure, .options, .ddl:
            WorkspaceDatabaseObjectDetailsTabContent(
                state: detailsState,
                tab: tab,
                retry: retry,
                canEditSchema: canEditSchema,
                schemaEditingDescriptor: schemaEditingDescriptor,
                schemaEditor: schemaEditor,
                tableOptions: $tableOptions,
                selectedSchemaColumnID: $selectedSchemaColumnID,
                addSchemaColumn: addSchemaColumn,
                duplicateSchemaColumn: duplicateSchemaColumn,
                updateSchemaColumn: updateSchemaColumn,
                setSchemaColumnPrimaryKey: setSchemaColumnPrimaryKey,
                deleteSchemaColumn: deleteSchemaColumn
            )
            .equatable()

        case .indexes:
            WorkspaceDatabaseIndexesView(
                state: indexesState,
                indexes: schemaEditor.indexes,
                descriptor: schemaEditingDescriptor,
                availableColumnNames: schemaEditor.columns
                    .filter { !$0.isDeleted }
                    .map(\.definition.name)
                    .filter { !$0.isEmpty },
                selection: $selectedSchemaIndexID,
                retry: retry,
                isEditable: canEditSchema,
                add: addSchemaIndex,
                duplicate: duplicateSchemaIndex,
                update: updateSchemaIndex,
                delete: deleteSchemaIndex
            )
        }
    }
}
