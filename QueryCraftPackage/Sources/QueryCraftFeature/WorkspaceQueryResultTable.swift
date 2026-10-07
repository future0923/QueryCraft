import AppKit
import SwiftUI

struct WorkspaceQueryResultTable: NSViewRepresentable {
    let page: WorkspaceQueryResultPage
    let nullDisplayText: String
    let emptyStringDisplayText: String
    let copyIncludesColumnNames: Bool
    var formatsTimestamps: Bool = true
    let cellFont: NSFont
    let exportController: WorkspaceDataExportController
    let searchController: WorkspaceGridSearchController
    let pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate]
    let cellEditRequest: @MainActor (WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellEditRequest?
    let prepareCellEdit: @MainActor (WorkspaceDatabaseDataCellEditTarget) ->
        WorkspaceDatabaseDataCellInlineEditContext?
    let updateCellEdit: @MainActor (
        WorkspaceDatabaseDataCellInlineEditContext,
        WorkspaceDatabaseInspectorMutation
    ) -> Void
    let discardPendingUpdates: @MainActor (
        [WorkspaceDatabaseInspectorPendingUpdate]
    ) -> Void
    let pendingDeleteRowIndexes: IndexSet
    let deleteRows: (@MainActor (IndexSet) -> Void)?
    let updateInspectorContext: @MainActor (WorkspaceQueryResultInspectorContext) -> Void

    init(
        page: WorkspaceQueryResultPage,
        nullDisplayText: String,
        emptyStringDisplayText: String,
        copyIncludesColumnNames: Bool,
        formatsTimestamps: Bool = true,
        cellFont: NSFont,
        exportController: WorkspaceDataExportController,
        searchController: WorkspaceGridSearchController,
        pendingUpdates: [WorkspaceDatabaseInspectorPendingUpdate],
        pendingDeleteRowIndexes: IndexSet = [],
        cellEditRequest: @escaping @MainActor (
            WorkspaceDatabaseDataCellEditTarget
        ) -> WorkspaceDatabaseDataCellEditRequest?,
        prepareCellEdit: @escaping @MainActor (
            WorkspaceDatabaseDataCellEditTarget
        ) -> WorkspaceDatabaseDataCellInlineEditContext?,
        updateCellEdit: @escaping @MainActor (
            WorkspaceDatabaseDataCellInlineEditContext,
            WorkspaceDatabaseInspectorMutation
        ) -> Void,
        discardPendingUpdates: @escaping @MainActor (
            [WorkspaceDatabaseInspectorPendingUpdate]
        ) -> Void,
        deleteRows: (@MainActor (IndexSet) -> Void)? = nil,
        updateInspectorContext: @escaping @MainActor (
            WorkspaceQueryResultInspectorContext
        ) -> Void
    ) {
        self.page = page
        self.nullDisplayText = nullDisplayText
        self.emptyStringDisplayText = emptyStringDisplayText
        self.copyIncludesColumnNames = copyIncludesColumnNames
        self.formatsTimestamps = formatsTimestamps
        self.cellFont = cellFont
        self.exportController = exportController
        self.searchController = searchController
        self.pendingUpdates = pendingUpdates
        self.pendingDeleteRowIndexes = pendingDeleteRowIndexes
        self.cellEditRequest = cellEditRequest
        self.prepareCellEdit = prepareCellEdit
        self.updateCellEdit = updateCellEdit
        self.discardPendingUpdates = discardPendingUpdates
        self.deleteRows = deleteRows
        self.updateInspectorContext = updateInspectorContext
    }

    func makeCoordinator() -> WorkspaceQueryResultTableCoordinator {
        WorkspaceQueryResultTableCoordinator(
            page: page,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            copyIncludesColumnNames: copyIncludesColumnNames,
            formatsTimestamps: formatsTimestamps,
            cellFont: cellFont,
            exportController: exportController,
            searchController: searchController,
            pendingUpdates: pendingUpdates,
            cellEditRequest: cellEditRequest,
            prepareCellEdit: prepareCellEdit,
            updateCellEdit: updateCellEdit,
            discardPendingUpdates: discardPendingUpdates,
            pendingDeleteRowIndexes: pendingDeleteRowIndexes,
            deleteRows: deleteRows,
            updateInspectorContext: updateInspectorContext
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.update(
            page: page,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            copyIncludesColumnNames: copyIncludesColumnNames,
            formatsTimestamps: formatsTimestamps,
            cellFont: cellFont,
            pendingUpdates: pendingUpdates,
            cellEditRequest: cellEditRequest,
            prepareCellEdit: prepareCellEdit,
            updateCellEdit: updateCellEdit,
            discardPendingUpdates: discardPendingUpdates,
            pendingDeleteRowIndexes: pendingDeleteRowIndexes,
            deleteRows: deleteRows,
            updateInspectorContext: updateInspectorContext
        )
    }
}
