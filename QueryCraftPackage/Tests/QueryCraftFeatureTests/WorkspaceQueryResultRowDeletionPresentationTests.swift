import AppKit
import Testing

@testable import QueryCraftFeature

struct WorkspaceQueryResultRowDeletionPresentationTests {
    @MainActor
    @Test
    func queryResultGridForwardsDeleteRowsHandler() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(id: 0, values: [.text("42")]),
        ])
        let page = WorkspaceQueryResultPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "id")],
            store: store,
            rowCount: 1
        )
        var requestedRows: IndexSet?
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            deleteRows: { rows in requestedRows = rows }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(tableView.canDeleteDataRowsHandler?(IndexSet(integer: 0)) == true)
        tableView.deleteDataRowsHandler?(IndexSet(integer: 0))
        #expect(requestedRows == IndexSet(integer: 0))
    }

    @MainActor
    @Test
    func queryResultCellMenuOffersDeleteForSelectedRows() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(id: 0, values: [.text("42")]),
            WorkspaceDatabaseDataRow(id: 1, values: [.text("43")]),
        ])
        let page = WorkspaceQueryResultPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "id")],
            store: store,
            rowCount: 2
        )
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            deleteRows: { _ in }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        tableView.selectRowIndexes(
            IndexSet(integersIn: 0...1),
            byExtendingSelection: false
        )

        let menuItems = try #require(
            tableView.additionalCellContextMenuItemsProvider?(0, 1)
        )
        let deleteItem = try #require(
            menuItems.first {
                $0.title == AppCopy.current.text("删除 2 行", "Delete 2 Rows")
            }
        )
        #expect(deleteItem.isEnabled)
        #expect((deleteItem.representedObject as? IndexSet) == IndexSet(integersIn: 0...1))
    }

    @MainActor
    @Test
    func pendingDeletedRowsCanUndoDeletion() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(id: 0, values: [.text("42")]),
        ])
        let page = WorkspaceQueryResultPage(
            columns: [
                WorkspaceDatabaseDataColumn(
                    id: 0,
                    name: "id",
                    origin: .init(
                        databaseName: "app",
                        tableName: "users",
                        columnName: "id"
                    )
                ),
            ],
            store: store,
            rowCount: 1
        )
        var requestedRows: IndexSet?
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            prepareCellEdit: { target in
                WorkspaceDatabaseDataCellInlineEditContext(
                    rowIndex: target.rowIndex,
                    dataColumnIndex: target.dataColumnIndex,
                    columnName: "id",
                    initialText: "42",
                    initialMutation: .value("42")
                )
            },
            pendingDeleteRowIndexes: IndexSet(integer: 0),
            deleteRows: { rows in requestedRows = rows }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(tableView.canDeleteDataRowsHandler?(IndexSet(integer: 0)) == true)
        #expect(tableView.canEditCellHandler?(0, 1) == false)
        let menuItems = try #require(
            tableView.additionalCellContextMenuItemsProvider?(0, 1)
        )
        let undoItem = try #require(
            menuItems.first {
                $0.title == AppCopy.current.text("撤销删除", "Undo Delete")
            }
        )
        #expect(undoItem.isEnabled)
        #expect(undoItem.representedObject as? IndexSet == IndexSet(integer: 0))
        tableView.deleteDataRowsHandler?(IndexSet(integer: 0))
        #expect(requestedRows == IndexSet(integer: 0))
    }

    @MainActor
    @Test
    func queryResultTableRefreshesAfterRowsAreRemovedFromStore() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(id: 0, values: [.text("first")]),
            WorkspaceDatabaseDataRow(id: 1, values: [.text("second")]),
            WorkspaceDatabaseDataRow(id: 2, values: [.text("third")]),
        ])
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: store,
                rowCount: 3
            )
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        #expect(coordinator.numberOfRows(in: tableView) == 3)

        try await store.remove(rowsAt: IndexSet(integer: 1))
        coordinator.update(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: store,
                rowCount: 2
            )
        )

        #expect(coordinator.numberOfRows(in: tableView) == 2)
        #expect(tableView.numberOfRows == 2)
    }
}
