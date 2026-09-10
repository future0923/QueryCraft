import AppKit
import Testing

@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchBatchDeletionPresentationTests {
    @Test
    func selectedDocumentsShareOneTextOnlyDeleteAction() throws {
        let page = makePage()
        var requests: [IndexSet] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in },
            selectedRowIndexes: [0, 1, 2],
            rowActionKind: .elasticsearchDocument,
            deleteRows: { requests.append($0) }
        )
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let items = try #require(table.additionalCellContextMenuItemsProvider?(1, 1))
        let deletion = try #require(items.last)
        #expect(deletion.title == AppCopy.current.text("删除 3 篇文档", "Delete 3 Documents"))
        #expect(items.allSatisfy { $0.image == nil })
        #expect(deletion.isEnabled)
        #expect(NSApp.sendAction(try #require(deletion.action), to: deletion.target, from: deletion))
        #expect(requests == [IndexSet([0, 1, 2])])

        // A mixed selection adds new deletions; an entirely marked selection undoes them.
        for markedRows: IndexSet in [[0], [0, 1, 2]] {
            coordinator.update(
                page: page,
                isFetching: false,
                sortData: { _ in },
                pendingDeleteRowIndexes: markedRows,
                selectedRowIndexes: [0, 1, 2],
                rowActionKind: .elasticsearchDocument,
                deleteRows: { requests.append($0) }
            )
            let updatedItems = try #require(table.additionalCellContextMenuItemsProvider?(0, 1))
            let item = try #require(updatedItems.last)
            #expect(item.title == (markedRows.count == 3
                ? AppCopy.current.text("撤销删除", "Undo Delete")
                : AppCopy.current.text("删除 3 篇文档", "Delete 3 Documents")))
            #expect(item.isEnabled)
            #expect(table.canDeleteDataRowsHandler?([0, 1, 2]) == true)
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(requests.last == [0, 1, 2])
        }
    }

    @Test
    func disabledDeletionDisablesMenuAndKeyboardAction() throws {
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: makePage(),
            isFetching: false,
            sortData: { _ in },
            pendingDeleteRowIndexes: [0, 1],
            selectedRowIndexes: [0, 1],
            rowActionKind: .elasticsearchDocument
        )
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let items = try #require(table.additionalCellContextMenuItemsProvider?(0, 1))
        let item = try #require(items.last)
        #expect(!item.isEnabled)
        #expect(table.canDeleteDataRowsHandler?([0, 1]) == false)
    }

    @Test
    func bothDeleteKeysSupportMultipleDocuments() throws {
        try WorkspaceDatabaseDataPendingPresentationTests()
            .elasticsearchDocumentDeleteKeysDeleteSelectedRows()
    }

    @Test
    func textEditorRetainsDeleteKeys() {
        WorkspaceDatabaseDataPendingPresentationTests()
            .textEditorKeepsDeleteKeyForTextEditing()
    }

    @Test
    func relationalMultirowDeletionPresentationIsUnchanged() throws {
        try WorkspaceDatabaseDataPendingPresentationTests()
            .pendingDeleteImmediatelyRefreshesEverySelectedVisibleRow()
    }

    @Test
    func fallingBackAPageKeepsTheActiveColumnAndHorizontalViewport() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let columns = (0..<8).map { WorkspaceDatabaseDataColumn(id: $0, name: "field_\($0)") }
            let makePage: (Int, Int) -> WorkspaceDatabaseDataPage = { offset, count in
                WorkspaceDatabaseDataPage(
                    columns: columns,
                    rows: (0..<count).map { row in
                        WorkspaceDatabaseDataRow(id: row, values: columns.map { .text("value_\($0.id)") })
                    },
                    offset: offset, limit: 3, hasNextPage: false
                )
            }
            let oldPage = makePage(6, 1)
            let coordinator = WorkspaceDatabaseDataTableCoordinator(
                page: oldPage, isFetching: false, sortData: { _ in },
                selectedRowIndexes: [0], rowActionKind: .elasticsearchDocument
            )
            let scrollView = coordinator.makeScrollView()
            scrollView.appearance = NSAppearance(named: appearance)
            let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
            scrollView.frame = NSRect(x: 0, y: 0, width: 180, height: 320)
            scrollView.layoutSubtreeIfNeeded()
            let coordinate = WorkspaceGridCoordinate(row: 0, column: 6)
            table.selectGridRange(anchor: coordinate, active: coordinate)
            table.scrollColumnToVisible(6)
            let horizontalOrigin = scrollView.contentView.bounds.origin.x
            let widths = table.tableColumns.map(\.width)
            #expect(horizontalOrigin > 0)

            coordinator.update(
                page: oldPage, isFetching: true, sortData: { _ in },
                selectedRowIndexes: [], rowActionKind: .elasticsearchDocument
            )
            coordinator.update(
                page: makePage(3, 3), isFetching: false, sortData: { _ in },
                selectedRowIndexes: [0], rowActionKind: .elasticsearchDocument
            )
            #expect(table.gridSelection.active == coordinate)
            #expect(table.selectedDataRowIndexesForActions == [0])
            #expect(table.tableColumns.map(\.width) == widths)
            #expect(scrollView.contentView.bounds.origin.x == horizontalOrigin)
        }
    }

    private func makePage() -> WorkspaceDatabaseDataPage {
        WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "_id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: (0..<3).map {
                WorkspaceDatabaseDataRow(id: $0, values: [.text(String($0)), .text("before")])
            },
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
    }
}
