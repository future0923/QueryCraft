import SwiftUI

struct WorkspaceDatabaseDataView: Equatable, View {
    let state: WorkspaceDatabaseDataState
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
    @State private var preferences = ApplicationPreferences.shared

    nonisolated static func == (
        lhs: WorkspaceDatabaseDataView,
        rhs: WorkspaceDatabaseDataView
    ) -> Bool {
        lhs.appliedDataFilter == rhs.appliedDataFilter
            && lhs.isDataFilterPresented == rhs.isDataFilterPresented
            && lhs.detailsStateForDataFilter == rhs.detailsStateForDataFilter
            && lhs.rowInsertEditor == rhs.rowInsertEditor
            && lhs.pendingLoadedUpdates == rhs.pendingLoadedUpdates
            && lhs.pendingDeleteRowIndexes == rhs.pendingDeleteRowIndexes
            && lhs.selectedDataRowIndexes == rhs.selectedDataRowIndexes
            && lhs.rowActionKind == rhs.rowActionKind
            && statesRenderEqually(lhs.state, rhs.state)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isDataFilterPresented {
                WorkspaceDatabaseDataFilterPanel(
                    detailsState: detailsStateForDataFilter,
                    editor: dataFilterEditor,
                    retryDetails: retryDataFilterDetails,
                    close: closeDataFilter,
                    clearAndClose: {
                        clearDataFilter()
                        closeDataFilter()
                    },
                    apply: applyDataFilter
                )
            } else if appliedDataFilter.isActive {
                WorkspaceDatabaseDataFilterSummaryBar(
                    filter: appliedDataFilter,
                    edit: editDataFilter,
                    clear: clearDataFilter
                )
            }

            WorkspaceGridSearchBar(controller: searchController)
                .frame(
                    height: searchController.isPresented
                        ? nil
                        : 0
                )
                .opacity(searchController.isPresented ? 1 : 0)
                .clipped()
                .accessibilityHidden(!searchController.isPresented)

            if let page = state.page {
                pageContent(page, isFetching: state.isFetching)
            } else {
                switch state {
                case .notLoaded, .loading:
                    ProgressView(
                        AppCopy.current.text("正在获取数据行…", "Fetching rows...")
                    )
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("databaseObjectDataLoading")

                case .stopped:
                    ContentUnavailableView {
                        Label(
                            AppCopy.current.text("已停止获取", "Fetching Stopped"),
                            systemImage: "stop.circle"
                        )
                    } description: {
                        Text(
                            AppCopy.current.text(
                                "未收到任何行。",
                                "No rows were received."
                            )
                        )
                    } actions: {
                        Button(
                            AppCopy.current.text("重试", "Retry"),
                            systemImage: "arrow.clockwise",
                            action: retry
                        )
                    }

                case let .failed(message):
                    ContentUnavailableView {
                        Label(
                            AppCopy.current.text("无法加载数据", "Unable to Load Data"),
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(message)
                    } actions: {
                        Button(
                            AppCopy.current.text("重试", "Retry"),
                            systemImage: "arrow.clockwise",
                            action: retry
                        )
                    }

                case .fetching, .loaded:
                    EmptyView()
                }
            }

        }
        .focusedSceneValue(
            \.workspaceDataExportActions,
            exportCommandActions
        )
        .focusedSceneValue(
            \.workspaceGridSearchActions,
            searchCommandActions
        )
        .onChange(of: state.page?.revision, initial: true) {
            _, pageRevision in
            guard pageRevision == nil else { return }
            searchController.clearSource()
            searchController.dismiss()
        }
    }

    @ViewBuilder
    private func pageContent(
        _ page: WorkspaceDatabaseDataPage,
        isFetching: Bool
    ) -> some View {
        WorkspaceDatabaseDataTable(
            page: page,
            isFetching: isFetching,
            usesAlternatingRows: preferences.usesAlternatingTableRows,
            nullDisplayText:
                preferences.tableNullDisplayStyle.displayText,
            emptyStringDisplayText:
                preferences.tableEmptyStringDisplayStyle.displayText,
            copyIncludesColumnNames:
                preferences.copyIncludesColumnNames,
            cellFont: preferences.dataGridFont(),
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
            selectedRowIndexes: selectedDataRowIndexes,
            rowActionKind: rowActionKind,
            addRow: addRow,
            duplicateRow: duplicateRow,
            deleteRows: deleteRows,
            pasteRows: pasteRows,
            selectRowsForActions: selectRowsForActions
        )
    }

    private var databaseColumns: [WorkspaceDatabaseColumn] {
        guard case let .loaded(details) = detailsStateForDataFilter else {
            return []
        }
        return details.columns
    }

    private var exportCommandActions: WorkspaceDataExportCommandActions? {
        guard state.page?.rowCount ?? 0 > 0 else { return nil }
        return WorkspaceDataExportCommandActions(
            export: { exportController.presentOptions() }
        )
    }

    private var searchCommandActions: WorkspaceGridSearchCommandActions? {
        guard state.page?.rowCount ?? 0 > 0 else { return nil }
        return WorkspaceGridSearchCommandActions(
            search: searchController.present
        )
    }

    nonisolated static func statesRenderEqually(
        _ lhs: WorkspaceDatabaseDataState,
        _ rhs: WorkspaceDatabaseDataState
    ) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.loading, .loading):
            true
        case let (.fetching(lhsPage), .fetching(rhsPage)),
             let (.loaded(lhsPage), .loaded(rhsPage)):
            lhsPage.revision == rhsPage.revision
        case let (.stopped(lhsPage), .stopped(rhsPage)):
            lhsPage?.revision == rhsPage?.revision
        case let (.failed(lhsMessage), .failed(rhsMessage)):
            lhsMessage == rhsMessage
        default:
            false
        }
    }
}
