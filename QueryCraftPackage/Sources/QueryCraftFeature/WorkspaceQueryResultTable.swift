import AppKit
import SwiftUI

struct WorkspaceQueryResultTable: NSViewRepresentable {
    let page: WorkspaceQueryResultPage
    let nullDisplayText: String
    let emptyStringDisplayText: String
    let copyIncludesColumnNames: Bool
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
    let updateInspectorContext: @MainActor (WorkspaceQueryResultInspectorContext) -> Void

    func makeCoordinator() -> WorkspaceQueryResultTableCoordinator {
        WorkspaceQueryResultTableCoordinator(
            page: page,
            nullDisplayText: nullDisplayText,
            emptyStringDisplayText: emptyStringDisplayText,
            copyIncludesColumnNames: copyIncludesColumnNames,
            cellFont: cellFont,
            exportController: exportController,
            searchController: searchController,
            pendingUpdates: pendingUpdates,
            cellEditRequest: cellEditRequest,
            prepareCellEdit: prepareCellEdit,
            updateCellEdit: updateCellEdit,
            discardPendingUpdates: discardPendingUpdates,
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
            cellFont: cellFont,
            pendingUpdates: pendingUpdates,
            cellEditRequest: cellEditRequest,
            prepareCellEdit: prepareCellEdit,
            updateCellEdit: updateCellEdit,
            discardPendingUpdates: discardPendingUpdates,
            updateInspectorContext: updateInspectorContext
        )
    }
}
