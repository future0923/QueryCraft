import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceSQLGridHeaderTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func nativeHeaderActuallyDrawsTheThirdLine(appearance: NSAppearance.Name) throws {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 220, height: 100))
        table.appearance = NSAppearance(named: appearance)
        let header = WorkspaceGridHeaderView(frame: NSRect(x: 0, y: 0, width: 220, height: 64))
        table.headerView = header
        let column = NSTableColumn(identifier: .init("queryResult.column.0"))
        column.title = "id"
        column.width = 220
        table.addTableColumn(column)
        WorkspaceSQLGridHeader.configure(
            in: table, columns: [.init(id: 0, name: "id")], configuration: .init()
        )
        let cell = try #require(column.headerCell as? WorkspaceSQLGridHeaderCell)
        cell.comment = "用户编号"
        let before = try renderedHeader(header)
        cell.columnType = "BIGINT"
        header.needsDisplay = true
        let after = try renderedHeader(header)
        var changedPixels = 0
        for y in (after.pixelsHigh * 2 / 3)..<(after.pixelsHigh - 2) {
            for x in 0..<after.pixelsWide {
                if before.colorAt(x: x, y: y) != after.colorAt(x: x, y: y) {
                    changedPixels += 1
                }
            }
        }
        #expect(changedPixels > 20, "The type text must be visible in the bottom third of the header.")
    }

    @Test(arguments: [true, false], [true, false])
    func switchesChangeOnlyHeaderHeight(showsComments: Bool, showsTypes: Bool) throws {
        let page = makePage()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page, isFetching: false,
            sqlHeaderConfiguration: .init(), sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let column = table.tableColumns[1]
        column.width = 275
        table.selectGridRange(
            anchor: .init(row: 2, column: 1), active: .init(row: 2, column: 1)
        )
        coordinator.update(
            page: page, isFetching: false,
            sqlHeaderConfiguration: .init(showsComments: showsComments, showsTypes: showsTypes),
            sortData: { _ in }
        )

        let expectedHeight = CGFloat(28 + (showsComments ? 18 : 0) + (showsTypes ? 18 : 0))
        #expect(table.headerView?.frame.height == expectedHeight)
        #expect(table.tableColumns[1] === column)
        #expect(column.width == 275)
        #expect(table.gridSelection.active?.row == 2)
        #expect(column.headerCell.textColor == .controlAccentColor)
        let cell = try #require(column.headerCell as? WorkspaceSQLGridHeaderCell)
        #expect(cell.stringValue == "user_name")
        #expect(cell.showsComments == showsComments)
        #expect(cell.showsTypes == showsTypes)
    }

    @Test
    func lateMetadataAndRepeatedRefreshPreserveLayoutAndViewport() throws {
        let page = makePage()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page, isFetching: true,
            sqlHeaderConfiguration: .init(), sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        scrollView.layoutSubtreeIfNeeded()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let column = table.tableColumns[1]
        let cell = try #require(column.headerCell as? WorkspaceSQLGridHeaderCell)
        column.width = 275
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let origin = scrollView.contentView.bounds.origin
        let contentFrame = scrollView.contentView.frame
        #expect(cell.comment.isEmpty)
        #expect(cell.columnType == "varchar(100)")

        for fetching in [false, true, true, false] {
            coordinator.update(
                page: page, isFetching: fetching,
                sqlHeaderConfiguration: .init(columnDetails: [0: makeDetails()]),
                sortData: { _ in }
            )
            #expect(table.headerView?.frame.height == 64)
            #expect(scrollView.contentView.frame == contentFrame)
            #expect(scrollView.contentView.bounds.origin == origin)
            #expect(column.width == 275)
            #expect(column.headerCell === cell)
            #expect(cell.comment == "用户姓名")
            #expect(column.headerToolTip == "user_name\n用户姓名\nvarchar(100)")
        }
    }

    @Test
    func queryMetadataUpdatesWithoutReplacingColumnsAndNewResultClearsIt() throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "display_name", type: "varchar")]
        let page = WorkspaceQueryResultPage(columns: columns, store: store, rowCount: 0)
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page, sqlHeaderConfiguration: .init()
        )
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let column = table.tableColumns[1]
        column.width = 300

        coordinator.update(page: page, sqlHeaderConfiguration: .init(columnDetails: [0: makeDetails()]))
        let cell = try #require(column.headerCell as? WorkspaceSQLGridHeaderCell)
        #expect(cell.stringValue == "display_name")
        #expect(cell.comment == "用户姓名")
        #expect(cell.columnType == "varchar(100)")
        #expect(column.width == 300)

        coordinator.update(
            page: .init(columns: columns, store: try WorkspaceQueryResultStore(temporary: false), rowCount: 0),
            sqlHeaderConfiguration: .init()
        )
        #expect(table.tableColumns[1] === column)
        #expect(cell.comment.isEmpty)
        #expect(cell.columnType == "varchar")
        #expect(table.headerView?.frame.height == 64)
    }

    @Test
    func failedMetadataRefreshRetainsCommentsOnlyForTheSameObject() throws {
        let page = makePage()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page, isFetching: false,
            sqlHeaderConfiguration: .init(columnDetails: [0: makeDetails()], scope: "dbA.users"),
            sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let cell = try #require(table.tableColumns[1].headerCell as? WorkspaceSQLGridHeaderCell)
        coordinator.update(
            page: page, isFetching: false,
            sqlHeaderConfiguration: .init(scope: "dbA.users", retainsMissingDetails: true),
            sortData: { _ in }
        )
        #expect(cell.comment == "用户姓名")

        coordinator.update(
            page: page, isFetching: true,
            sqlHeaderConfiguration: .init(scope: "dbB.users", retainsMissingDetails: true),
            sortData: { _ in }
        )
        #expect(cell.comment.isEmpty)
        #expect(table.headerView?.frame.height == 64)
    }

    private func makePage() -> WorkspaceDatabaseDataPage {
        WorkspaceDatabaseDataPage(
            columns: [.init(id: 0, name: "user_name", type: "varchar(100)")],
            rows: (0..<30).map { .init(id: $0, values: [.text("Alice")]) },
            offset: 0, limit: 30, hasNextPage: false, sort: .ascending(columnName: "user_name")
        )
    }

    private func makeDetails() -> WorkspaceDatabaseColumn {
        .init(
            name: "user_name", type: "varchar(100)", collation: nil,
            isNullable: true, key: "", defaultValue: nil, extra: "", comment: "用户姓名"
        )
    }

    private func renderedHeader(_ header: WorkspaceGridHeaderView) throws -> NSBitmapImageRep {
        let bitmap = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
        header.cacheDisplay(in: header.bounds, to: bitmap)
        return bitmap
    }
}
