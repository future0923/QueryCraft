import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceGridHeaderSortTests {
    @Test(arguments: [WorkspaceDatabaseDataSort.none, .ascending(columnName: "name"), .descending(columnName: "name")])
    func menuOffersExplicitDatabaseDirections(_ initial: WorkspaceDatabaseDataSort) throws {
        var requests: [WorkspaceDatabaseDataSort] = []
        let coordinator = makeCoordinator(sort: initial, sortData: { requests.append($0) })
        let table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
        let header = try #require(table.headerView as? WorkspaceGridHeaderView)
        header.layout()
        let column = table.tableColumns[1]
        coordinator.tableView(table, didClick: column)
        header.columnSelectionHandler?(1, false)
        #expect(requests.isEmpty)
        #expect(table.gridSelection.cellCount == 2)
        let button = try #require(header.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "sortGridColumn.\(column.identifier.rawValue)"
        })
        #expect(button.isEnabled)
        #expect(button.frame.maxX < header.headerRect(ofColumn: 1).maxX - 4)
        let originalImage = button.image
        let originalFrame = button.frame
        let menu = coordinator.makeSortMenu(for: column)
        #expect(menu.items.count == 7)
        let choice = initial == .descending(columnName: "name") ? 0 : 1
        let item = menu.items[choice]
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(requests == [choice == 0 ? .ascending(columnName: "name") : .descending(columnName: "name")])
        header.layout()
        #expect(button.image !== originalImage)
        #expect(button.frame == originalFrame)
        #expect(header.sortDirections[column.identifier] == requests.first)
        #expect(table.gridSelection.cellCount == 2)
        _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(requests.count == 1) // Request in progress cannot be duplicated.
    }

    @Test
    func fetchingKeepsButtonVisibleButDisabled() throws {
        let coordinator = makeCoordinator(fetching: true, sortData: { _ in Issue.record("Unexpected sort") })
        let table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
        let header = try #require(table.headerView as? WorkspaceGridHeaderView)
        header.layout()
        let buttons = header.subviews.compactMap { $0 as? NSButton }.filter {
            $0.accessibilityIdentifier().hasPrefix("sortGridColumn.")
        }
        #expect(buttons.count == 1)
        #expect(buttons.first?.isEnabled == false)
    }

    @Test
    func buttonFollowsColumnAfterReordering() throws {
        var requests: [WorkspaceDatabaseDataSort] = []
        let coordinator = makeCoordinator(extraColumn: true, sortData: { requests.append($0) })
        let table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
        let header = try #require(table.headerView as? WorkspaceGridHeaderView)
        table.moveColumn(1, toColumn: 2)
        header.layout()
        let button = try #require(header.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "sortGridColumn.databaseData.column.0"
        })
        #expect(button.frame.maxX < header.headerRect(ofColumn: 2).maxX)
        #expect(button.frame.minX > header.headerRect(ofColumn: 2).minX)
        let item = coordinator.makeSortMenu(for: table.tableColumns[2]).items[1]
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(requests == [.descending(columnName: "name")])
    }

    @Test func currentPageActionsNeverRequestTheDatabase() throws {
        var local: [WorkspaceDatabaseDataSort] = []
        let page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "name", type: "varchar")],
            rows: [.init(id: 5, values: [.text("A")])], offset: 20, limit: 20, hasNextPage: true)
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false,
            sqlHeaderConfiguration: .init(), sortData: { _ in Issue.record("Unexpected database request") },
            sortCurrentPage: { local.append($0) })
        let table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
        let menu = coordinator.makeSortMenu(for: table.tableColumns[1])
        for index in [3, 4] {
            let item = menu.items[index]
            #expect(item.isEnabled)
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(local == [.ascending(columnName: "name"), .descending(columnName: "name")])
    }

    @Test func pageSortUsesNumbersAndKeepsRowIdentityAndPagination() {
        let page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "amount", type: "decimal(20, 2)")],
            rows: [.init(id: 41, values: [.text("10.25")]), .init(id: 7, values: [.text("-2.5")]),
                   .init(id: 93, values: [.text("10.25")]), .init(id: 12, values: [.null])],
            offset: 200, limit: 200, hasNextPage: true, sort: .descending(columnName: "amount"))
        let ascending = WorkspacePageSorting.sorted(page, by: .ascending(columnName: "amount"))
        #expect(ascending.rows.map(\.id) == [12, 7, 41, 93])
        #expect(ascending.offset == 200 && ascending.limit == 200 && ascending.hasNextPage)
        #expect(ascending.sort == page.sort)
        #expect(ascending.localSort == .ascending(columnName: "amount"))
        #expect(WorkspacePageSorting.sorted(page, by: .descending(columnName: "amount")).rows.map(\.id) == [41, 93, 7, 12])
        #expect(page.rows.map(\.id) == [41, 7, 93, 12])
    }

    @Test func localSortDirectionOverridesDatabaseDirectionInTheHeader() throws {
        var page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "name", type: "varchar"), .init(id: 1, name: "other", type: "int")],
            rows: [.init(id: 0, values: [.text("A"), .text("2")])], offset: 0, limit: 200,
            hasNextPage: false, sort: .descending(columnName: "name"))
        page.localSort = .ascending(columnName: "other")
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false,
            sqlHeaderConfiguration: .init(), sortData: { _ in })
        let table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
        let header = try #require(table.headerView as? WorkspaceGridHeaderView)
        #expect(header.sortDirections[table.tableColumns[1].identifier] == WorkspaceDatabaseDataSort.none)
        #expect(header.sortDirections[table.tableColumns[2].identifier] == .ascending(columnName: "other"))
    }

    private func makeCoordinator(sort: WorkspaceDatabaseDataSort = .none, fetching: Bool = false,
                                 extraColumn: Bool = false,
                                 sortData: @escaping (WorkspaceDatabaseDataSort) -> Void) -> WorkspaceDatabaseDataTableCoordinator {
        var columns = [WorkspaceDatabaseDataColumn(id: 0, name: "name", type: "varchar")]
        if extraColumn { columns.append(.init(id: 1, name: "other", type: "varchar")) }
        return WorkspaceDatabaseDataTableCoordinator(page: .init(columns: columns,
            rows: [.init(id: 0, values: [.text("A"), .text("x")]), .init(id: 1, values: [.text("B"), .text("y")])],
            offset: 0, limit: 200, hasNextPage: false, sort: sort), isFetching: fetching,
            sqlHeaderConfiguration: .init(), sortData: sortData)
    }
}
