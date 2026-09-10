import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceGridColumnSizingTests {
    @Test
    func samplesRowsWithinTheConfiguredQueryResultWindow() {
        let columns = (0..<12).map {
            WorkspaceDatabaseDataColumn(id: $0, name: "column_\($0)")
        }
        var requestedRows: [Int] = []

        _ = WorkspaceGridColumnSizing.automaticWidths(
            columns: columns,
            rowCount: 100_000,
            maximumConsideredRows: 256
        ) { row in
            requestedRows.append(row)
            return WorkspaceDatabaseDataRow(
                id: row,
                values: columns.map { .text("value_\($0.id)") }
            )
        }

        #expect(requestedRows.count == 30)
        #expect(requestedRows.first == 0)
        #expect(requestedRows.last == 255)
        #expect(Array(requestedRows.prefix(15)) == Array(0..<15))
        #expect(requestedRows.allSatisfy { $0 < 256 })
    }

    @Test
    func reducesSamplingForVeryWideResults() {
        let columns = (0..<51).map {
            WorkspaceDatabaseDataColumn(id: $0, name: "column_\($0)")
        }
        var requestedRows: [Int] = []

        _ = WorkspaceGridColumnSizing.automaticWidths(
            columns: columns,
            rowCount: 1_000,
            maximumConsideredRows: nil
        ) { row in
            requestedRows.append(row)
            return WorkspaceDatabaseDataRow(
                id: row,
                values: columns.map { _ in .text("value") }
            )
        }

        #expect(requestedRows.count == 10)
        #expect(requestedRows.first == 0)
        #expect(requestedRows.last == 999)
    }

    @Test
    func producesNaturalWidthsWithinAutomaticBounds() {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "id"),
            WorkspaceDatabaseDataColumn(id: 1, name: "user_phone"),
            WorkspaceDatabaseDataColumn(
                id: 2,
                name: String(repeating: "very_long_header_", count: 10)
            ),
        ]
        let row = WorkspaceDatabaseDataRow(
            id: 0,
            values: [
                .text("248177989345347445"),
                .text("13144332211"),
                .text(String(repeating: "中", count: 100)),
            ]
        )

        let widths = WorkspaceGridColumnSizing.automaticWidths(
            columns: columns,
            rowCount: 1,
            maximumConsideredRows: nil,
            rowAt: { _ in row }
        )

        #expect(widths[0, default: 0] > widths[1, default: 0])
        #expect(
            widths.values.allSatisfy {
                $0 >= WorkspaceGridColumnSizing.minimumColumnWidth
                    && $0
                        <= WorkspaceGridColumnSizing
                        .maximumAutomaticColumnWidth
            }
        )
        #expect(
            widths[2]
                == WorkspaceGridColumnSizing.maximumAutomaticColumnWidth
        )
    }

    @Test
    func keepsShortHeadersCompact() {
        let widths = WorkspaceGridColumnSizing.automaticWidths(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "source_code"),
            ],
            rowCount: 1,
            maximumConsideredRows: nil
        ) { _ in
            WorkspaceDatabaseDataRow(id: 0, values: [.text("3911")])
        }

        #expect(widths[0, default: 0] < 120)
    }

    @Test
    func resetButtonRestoresCurrentPageAutomaticWidths() throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("123456789012345678"), .text("Alice")]
                ),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: false
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        let dataColumn = try #require(tableView.tableColumns.dropFirst().first)
        let headerFont = try #require(dataColumn.headerCell.font)
        let automaticWidth = dataColumn.width
        dataColumn.width = 400

        let headerView = try #require(
            tableView.headerView as? WorkspaceGridHeaderView
        )
        #expect(headerView.frame.height == WorkspaceGridMetrics.headerHeight)
        #expect(dataColumn.headerCell.alignment == .left)
        #expect(
            NSFontManager.shared.traits(of: headerFont)
                .contains(.boldFontMask)
        )
        let resetButton = try #require(
            headerView.subviews.compactMap { $0 as? NSButton }.first
        )
        resetButton.performClick(nil)

        #expect(scrollView.hasHorizontalScroller)
        #expect(dataColumn.width == automaticWidth)
    }

    @Test
    func highlightsSortedTableDataHeader() throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "id"),
                WorkspaceDatabaseDataColumn(id: 1, name: "name"),
            ],
            rows: [],
            offset: 0,
            limit: 200,
            hasNextPage: false,
            sort: .descending(columnName: "name")
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page,
            isFetching: false,
            sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        let dataColumns = Array(tableView.tableColumns.dropFirst())

        #expect(dataColumns[0].headerCell.textColor == .labelColor)
        #expect(dataColumns[1].headerCell.textColor == .controlAccentColor)
    }

    @Test
    func drawsEachHeaderTitleOncePerRefresh() throws {
        let tableView = NSTableView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 100)
        )
        let headerView = WorkspaceGridHeaderView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 240,
                height: WorkspaceGridMetrics.headerHeight
            )
        )
        tableView.headerView = headerView

        let tableColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("test.column")
        )
        let headerCell = CountingTableHeaderCell(textCell: "column_name")
        WorkspaceGridMetrics.configureHeaderCell(headerCell)
        tableColumn.headerCell = headerCell
        tableColumn.width = 160
        tableView.addTableColumn(tableColumn)

        let bitmap = try #require(
            headerView.bitmapImageRepForCachingDisplay(in: headerView.bounds)
        )
        headerView.cacheDisplay(in: headerView.bounds, to: bitmap)

        #expect(headerCell.drawInteriorCallCount == 1)
    }

    @Test
    func tableDataUpdatesPreserveUserWidth() throws {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "id"),
        ]
        let firstPage = WorkspaceDatabaseDataPage(
            columns: columns,
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("1")]),
            ],
            offset: 0,
            limit: 200,
            hasNextPage: true
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: firstPage,
            isFetching: false,
            sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        let dataColumn = try #require(tableView.tableColumns.dropFirst().first)
        dataColumn.width = 275

        coordinator.update(
            page: WorkspaceDatabaseDataPage(
                columns: columns,
                rows: [
                    WorkspaceDatabaseDataRow(
                        id: 200,
                        values: [.text("123456789012345678")]
                    ),
                ],
                offset: 200,
                limit: 200,
                hasNextPage: false
            ),
            isFetching: false,
            sortData: { _ in }
        )

        #expect(dataColumn.width == 275)
    }

    @Test
    func samePageReplacementPreservesViewportAndValidCellSelection() throws {
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "value")]
        let originalRows = (0..<30).map {
            WorkspaceDatabaseDataRow(
                id: $0,
                values: [.text("before-\($0)")]
            )
        }
        let firstPage = WorkspaceDatabaseDataPage(
            columns: columns,
            rows: originalRows,
            offset: 0,
            limit: 30,
            hasNextPage: false
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: firstPage,
            isFetching: false,
            sortData: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        scrollView.layoutSubtreeIfNeeded()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 20, column: 1),
            active: WorkspaceGridCoordinate(row: 20, column: 1)
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let originBeforeRefresh = scrollView.contentView.bounds.origin

        var refreshedRows = originalRows
        refreshedRows[20] = WorkspaceDatabaseDataRow(
            id: 20,
            values: [.text("after-20")]
        )
        coordinator.update(
            page: WorkspaceDatabaseDataPage(
                columns: columns,
                rows: refreshedRows,
                offset: 0,
                limit: 30,
                hasNextPage: false
            ),
            isFetching: false,
            sortData: { _ in }
        )

        #expect(tableView.gridSelection.active?.row == 20)
        #expect(scrollView.contentView.bounds.origin == originBeforeRefresh)
        #expect(
            coordinator.workspaceTableViewCopySnapshot(tableView)
                .rowAt(20)?.values == [.text("after-20")]
        )
    }

    @Test
    func queryAppendPreservesWidthAndNewResultRecalculates() async throws {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "value"),
        ]
        let firstStore = try WorkspaceQueryResultStore(temporary: false)
        try await firstStore.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("short")]
            ),
        ])
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: firstStore,
                rowCount: 1
            )
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        let dataColumn = try #require(tableView.tableColumns.dropFirst().first)
        dataColumn.width = 275

        try await firstStore.append([
            WorkspaceDatabaseDataRow(
                id: 1,
                values: [.text("a much longer appended value")]
            ),
        ])
        coordinator.update(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: firstStore,
                rowCount: 2
            )
        )
        #expect(dataColumn.width == 275)

        let secondStore = try WorkspaceQueryResultStore(temporary: false)
        try await secondStore.append([
            WorkspaceDatabaseDataRow(
                id: 0,
                values: [.text("new result")]
            ),
        ])
        coordinator.update(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: secondStore,
                rowCount: 1
            )
        )

        #expect(dataColumn.width != 275)
    }

    @Test
    func queryAppendKeepsAutomaticColumnWidthsStable() async throws {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "input_user_id"),
        ]
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(id: 0, values: [.null]),
        ])
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: store,
                rowCount: 1
            )
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )
        let dataColumn = try #require(tableView.tableColumns.dropFirst().first)
        let initialWidth = dataColumn.width

        try await store.append([
            WorkspaceDatabaseDataRow(
                id: 1,
                values: [.text("1720747023494045696")]
            ),
        ])
        coordinator.update(
            page: WorkspaceQueryResultPage(
                columns: columns,
                store: store,
                rowCount: 2
            )
        )

        #expect(initialWidth == 160)
        #expect(dataColumn.width == initialWidth)
    }
}

@MainActor
private final class CountingTableHeaderCell: NSTableHeaderCell {
    private(set) var drawInteriorCallCount = 0

    override func drawInterior(
        withFrame cellFrame: NSRect,
        in controlView: NSView
    ) {
        drawInteriorCallCount += 1
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}
