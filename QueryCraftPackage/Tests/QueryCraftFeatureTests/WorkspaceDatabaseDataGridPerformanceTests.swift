import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceDatabaseDataGridPerformanceTests {
    @Test func keepsOneHundredThousandLogicalRowsVirtualized() {
        let harness = LargeGridHarness(
            rowCount: 100_000,
            columnCount: 30
        )
        let scrollView = harness.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        scrollView.layoutSubtreeIfNeeded()

        let duration = ContinuousClock().measure {
            harness.tableView.reloadData()
            harness.tableView.scrollRowToVisible(99_999)
            harness.tableView.layoutSubtreeIfNeeded()
            harness.tableView.displayIfNeeded()
        }

        let visibleRows = harness.tableView.rows(
            in: harness.tableView.visibleRect
        )
        guard visibleRows.location != NSNotFound else {
            Issue.record("The table did not produce a visible row range.")
            return
        }

        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            _ = harness.tableView.rowView(
                atRow: row,
                makeIfNecessary: true
            )
        }
        let rowViews = harness.tableView.subviews.compactMap {
            $0 as? WorkspaceDatabaseDataRowView
        }

        #expect(harness.tableView.numberOfRows == 100_000)
        #expect(rowViews.count <= visibleRows.length + 2)
        #expect(rowViews.allSatisfy { $0.subviews.isEmpty })
        #expect(duration < .seconds(2))
    }

    @Test func repeatedlyScrollsLargeDirectDrawGridWithoutCellViews() {
        let harness = LargeGridHarness(
            rowCount: 100_000,
            columnCount: 30
        )
        let scrollView = harness.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        scrollView.layoutSubtreeIfNeeded()
        harness.tableView.reloadData()

        let duration = ContinuousClock().measure {
            for row in stride(from: 0, to: 100_000, by: 5_000) {
                harness.tableView.scrollRowToVisible(row)
                harness.tableView.layoutSubtreeIfNeeded()
                harness.tableView.displayIfNeeded()
            }
        }

        let visibleRows = harness.tableView.rows(
            in: harness.tableView.visibleRect
        )
        guard visibleRows.location != NSNotFound else {
            Issue.record("The table did not produce a visible row range.")
            return
        }
        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            _ = harness.tableView.rowView(
                atRow: row,
                makeIfNecessary: true
            )
        }
        let rowViews = harness.tableView.subviews.compactMap {
            $0 as? WorkspaceDatabaseDataRowView
        }

        #expect(rowViews.count <= visibleRows.length + 2)
        #expect(rowViews.allSatisfy { $0.subviews.isEmpty })
        #expect(duration < .seconds(3))
    }

    @Test func snapshotsOnlyTheVisibleColumnDuringLargeGridDragging() {
        let harness = LargeGridHarness(
            rowCount: 100_000,
            columnCount: 30
        )
        let scrollView = harness.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 1_200, height: 600)
        scrollView.layoutSubtreeIfNeeded()
        harness.tableView.reloadData()
        harness.tableView.scrollRowToVisible(50_000)
        harness.tableView.layoutSubtreeIfNeeded()
        harness.tableView.displayIfNeeded()

        let duration = ContinuousClock().measure {
            harness.tableView.updateColumnDragVisual(
                column: 1,
                distance: 80
            )
        }

        #expect(
            harness.tableView.draggedColumnIdentifier
                == harness.tableView.tableColumns[1].identifier
        )
        #expect(duration < .milliseconds(250))

        harness.tableView.endColumnDragVisual()
        #expect(harness.tableView.draggedColumnIdentifier == nil)
    }

    @Test func comparesSharedLargePageSnapshotsInConstantTime() {
        let rowStore = WorkspaceDatabaseDataRowStore(
            rows: (0..<100_000).map { row in
                WorkspaceDatabaseDataRow(id: row, values: [])
            }
        )
        let first = WorkspaceDatabaseDataPage(
            columns: [],
            rowStore: rowStore,
            offset: 0,
            limit: 100_000,
            hasNextPage: false
        )
        let second = WorkspaceDatabaseDataPage(
            columns: [],
            rowStore: rowStore,
            offset: 0,
            limit: 100_000,
            hasNextPage: false
        )

        var equalCount = 0
        let duration = ContinuousClock().measure {
            for _ in 0..<1_000 where first == second {
                equalCount += 1
            }
        }

        #expect(equalCount == 1_000)
        #expect(duration < .milliseconds(100))
    }

}

@MainActor
private final class LargeGridHarness: NSObject {
    let tableView = WorkspaceDirectDrawTableView()

    private let rowCount: Int
    private let columnCount: Int
    private var columnIndexes: [
        NSUserInterfaceItemIdentifier: Int
    ] = [:]
    private let rowNumberIdentifier = NSUserInterfaceItemIdentifier(
        "performance.rowNumber"
    )
    private let rowViewIdentifier = NSUserInterfaceItemIdentifier(
        "performance.row"
    )

    init(rowCount: Int, columnCount: Int) {
        self.rowCount = rowCount
        self.columnCount = columnCount
    }

    func makeScrollView() -> NSScrollView {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowNumberIdentifier = rowNumberIdentifier

        let rowNumberColumn = NSTableColumn(
            identifier: rowNumberIdentifier
        )
        rowNumberColumn.width = 48
        tableView.addTableColumn(rowNumberColumn)

        for index in 0..<columnCount {
            let identifier = NSUserInterfaceItemIdentifier(
                "performance.column.\(index)"
            )
            columnIndexes[identifier] = index
            let column = NSTableColumn(identifier: identifier)
            column.width = 160
            tableView.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }
}

extension LargeGridHarness: NSTableViewDataSource {
    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { rowCount }
    }
}

extension LargeGridHarness: NSTableViewDelegate {
    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        nil
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        MainActor.assumeIsolated {
            let rowView: WorkspaceDatabaseDataRowView
            if let reused = tableView.makeView(
                withIdentifier: rowViewIdentifier,
                owner: self
            ) as? WorkspaceDatabaseDataRowView {
                rowView = reused
            } else {
                rowView = WorkspaceDatabaseDataRowView()
                rowView.identifier = rowViewIdentifier
            }
            rowView.configure(
                tableView: tableView,
                dataRow: WorkspaceDatabaseDataRow(
                    id: row,
                    values: (0..<columnCount).map {
                        .text("row \(row), column \($0)")
                    }
                ),
                rowIndex: row,
                columnIndexes: columnIndexes,
                rowNumberIdentifier: rowNumberIdentifier,
                accessibilityPrefix: "performance"
            )
            return rowView
        }
    }
}
