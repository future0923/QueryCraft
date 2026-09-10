import AppKit
import Testing
@testable import QueryCraftFeature

struct WorkspaceGridSelectionTests {
    @Test func representsLargeRectanglesWithOnlyAnchorAndActiveCells() {
        let selection = WorkspaceGridSelection(
            anchor: WorkspaceGridCoordinate(row: 0, column: 1),
            active: WorkspaceGridCoordinate(row: 999_999, column: 30)
        )

        #expect(selection.rows == 0...999_999)
        #expect(selection.columns == 1...30)
        #expect(selection.cellCount == 30_000_000)
        #expect(selection.contains(row: 400_000, column: 12))
        #expect(!selection.contains(row: 1_000_000, column: 12))
    }

    @Test func extendsFromTheOriginalAnchorInEveryDirection() {
        let anchor = WorkspaceGridCoordinate(row: 4, column: 3)
        let selection = WorkspaceGridSelection.cell(anchor).extending(
            to: WorkspaceGridCoordinate(row: 1, column: 7)
        )

        #expect(selection.anchor == anchor)
        #expect(selection.active == WorkspaceGridCoordinate(row: 1, column: 7))
        #expect(selection.rows == 1...4)
        #expect(selection.columns == 3...7)
    }

    @Test func allowsNativeDragProbeWhileKeepingRowNumbersFixed() {
        let rowNumber = "row-number"
        let dataColumn = "data"

        #expect(
            WorkspaceGridColumnReordering.allows(
                columnIdentifier: dataColumn,
                rowNumberIdentifier: rowNumber,
                proposedIndex: -1
            )
        )
        #expect(
            WorkspaceGridColumnReordering.allows(
                columnIdentifier: dataColumn,
                rowNumberIdentifier: rowNumber,
                proposedIndex: 1
            )
        )
        #expect(
            !WorkspaceGridColumnReordering.allows(
                columnIdentifier: dataColumn,
                rowNumberIdentifier: rowNumber,
                proposedIndex: 0
            )
        )
        #expect(
            !WorkspaceGridColumnReordering.allows(
                columnIdentifier: rowNumber,
                rowNumberIdentifier: rowNumber,
                proposedIndex: -1
            )
        )
    }

    @Test func computesContinuousColumnBandTransitionsAroundDraggedColumn() {
        let dragged = NSUserInterfaceItemIdentifier("dragged")
        let first = NSUserInterfaceItemIdentifier("first")
        let second = NSUserInterfaceItemIdentifier("second")
        let previous: [NSUserInterfaceItemIdentifier: CGFloat] = [
            dragged: 48,
            first: 208,
            second: 368,
        ]

        let movingRight = WorkspaceGridColumnTransition.make(
            previousPositions: previous,
            currentPositions: [
                first: 48,
                second: 208,
                dragged: 368,
            ],
            excluding: dragged
        )
        let movingLeft = WorkspaceGridColumnTransition.make(
            previousPositions: [
                first: 48,
                second: 208,
                dragged: 368,
            ],
            currentPositions: previous,
            excluding: dragged
        )

        #expect(
            movingRight
                == WorkspaceGridColumnTransition(
                    columnIdentifiers: [first, second],
                    offset: 160
                )
        )
        #expect(
            movingLeft
                == WorkspaceGridColumnTransition(
                    columnIdentifiers: [first, second],
                    offset: -160
                )
        )
    }
}

struct WorkspaceGridClipboardEncoderTests {
    private let rows = [
        WorkspaceDatabaseDataRow(
            id: 0,
            values: [.text("1"), .text("Alice")]
        ),
        WorkspaceDatabaseDataRow(
            id: 1,
            values: [.null, .text("line 1\nline \"2\"")]
        ),
        WorkspaceDatabaseDataRow(
            id: 2,
            values: [.binary(byteCount: 4), .text("")]
        ),
    ]

    @Test func copiesOneCellWithoutTSVQuoting() {
        let rows = rows
        let text = WorkspaceGridClipboardEncoder.encode(
            rows: .indexes(IndexSet(integer: 1)),
            columns: [WorkspaceGridCopyColumn(name: "name", dataIndex: 1)],
            includesColumnNames: false,
            rowAt: { rows[$0] }
        )

        #expect(text == "line 1\nline \"2\"")
    }

    @Test func copiesRectanglesAsTSVWithOptionalColumnNames() {
        let rows = rows
        let text = WorkspaceGridClipboardEncoder.encode(
            rows: .range(0...2),
            columns: [
                WorkspaceGridCopyColumn(name: "id", dataIndex: 0),
                WorkspaceGridCopyColumn(name: "display\tname", dataIndex: 1),
            ],
            includesColumnNames: true,
            rowAt: { rows[$0] }
        )

        let expected = "id\t\"display\tname\"\n"
            + "1\tAlice\n"
            + "NULL\t\"line 1\nline \"\"2\"\"\"\n"
            + "<BINARY 4 bytes>\t"
        #expect(text == expected)
    }

    @Test func usesTheConfiguredNullDisplayText() {
        let rows = rows
        let text = WorkspaceGridClipboardEncoder.encode(
            rows: .indexes(IndexSet(integer: 1)),
            columns: [WorkspaceGridCopyColumn(name: "id", dataIndex: 0)],
            includesColumnNames: false,
            nullDisplayText: "",
            rowAt: { rows[$0] }
        )

        #expect(text == "")
    }

    @Test func usesTheConfiguredEmptyStringDisplayText() {
        let rows = rows
        let text = WorkspaceGridClipboardEncoder.encode(
            rows: .indexes(IndexSet(integer: 2)),
            columns: [WorkspaceGridCopyColumn(name: "name", dataIndex: 1)],
            includesColumnNames: false,
            emptyStringDisplayText: "EMPTY",
            rowAt: { rows[$0] }
        )

        #expect(text == "EMPTY")
    }

    @Test func distinguishesNullFromEmptyStrings() {
        #expect(
            WorkspaceDatabaseDataCell.null.gridDisplayText(
                nullDisplayText: "NULL",
                emptyStringDisplayText: "EMPTY"
            ) == "NULL"
        )
        #expect(
            WorkspaceDatabaseDataCell.text("").gridDisplayText(
                nullDisplayText: "NULL",
                emptyStringDisplayText: "EMPTY"
            ) == "EMPTY"
        )
    }

    @Test func gridPreviewBoundsLargeTextWithoutChangingCopyValue() {
        let value = String(repeating: "x", count: 1_000_000)
        let cell = WorkspaceDatabaseDataCell.text(value)

        #expect(
            cell.gridPreviewText(
                nullDisplayText: "NULL",
                maximumCharacterCount: 300
            ).count == 303
        )
        #expect(cell.gridDisplayText == value)
        #expect(cell.textExceeds(characterCount: 300))
    }

    @Test func gridPreviewKeepsShortTextAndUnicodeCharactersIntact() {
        let cell = WorkspaceDatabaseDataCell.text("中文🙂")

        #expect(
            cell.gridPreviewText(
                nullDisplayText: "NULL",
                maximumCharacterCount: 300
            ) == "中文🙂"
        )
        #expect(!cell.textExceeds(characterCount: 300))
    }

    @Test func iteratesLargeContiguousSelectionsWithoutMaterializingIndexes() {
        let selectedRows = WorkspaceGridCopyRows.range(0...999_999)

        #expect(selectedRows.count == 1_000_000)
        #expect(selectedRows.first == 0)

        var visited = 0
        let completed = selectedRows.forEach { row in
            visited += 1
            return row < 2
        }
        #expect(!completed)
        #expect(visited == 3)
    }
}

@MainActor
struct WorkspaceDirectDrawTableViewCopyTests {
    @Test func copiesGridSelectionInVisibleColumnOrder() throws {
        let (tableView, source) = makeTable()
        tableView.moveColumn(2, toColumn: 1)
        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 0, column: 1),
            active: WorkspaceGridCoordinate(row: 1, column: 2)
        )

        tableView.copy(nil)

        #expect(
            tableView.copyPasteboard.string(forType: .string)
                == "Alice\t1\nBob\t2"
        )
        #expect(
            tableView.copyPasteboard.string(
                forType: WorkspaceGridClipboardEncoder.tabSeparatedTextType
            ) == "Alice\t1\nBob\t2"
        )
        withExtendedLifetime(source) {}
    }

    @Test func copiesSelectedRowsWithColumnNames() {
        let (tableView, source) = makeTable()
        tableView.selectRowIndexes(
            IndexSet([0, 1]),
            byExtendingSelection: false
        )

        tableView.copyWithColumnNames(nil)

        #expect(
            tableView.copyPasteboard.string(forType: .string)
                == "id\tname\n1\tAlice\n2\tBob"
        )
        withExtendedLifetime(source) {}
    }

    @Test func standardCopyCanIncludeColumnNamesByDefault() {
        let (tableView, source) = makeTable()
        tableView.copyIncludesColumnNames = true
        tableView.selectRowIndexes(
            IndexSet([0, 1]),
            byExtendingSelection: false
        )

        tableView.copy(nil)

        #expect(
            tableView.copyPasteboard.string(forType: .string)
                == "id\tname\n1\tAlice\n2\tBob"
        )
        withExtendedLifetime(source) {}
    }

    @Test func copiesAWholeColumnFromItsHeaderAction() {
        let (tableView, source) = makeTable()

        tableView.copyColumn(
            identifiedBy: TestGridDataSource.nameIdentifier,
            includesColumnName: true
        )

        #expect(
            tableView.copyPasteboard.string(forType: .string)
                == "name\nAlice\nBob"
        )
        withExtendedLifetime(source) {}
    }

    @Test func largeCopiesReturnBeforeEncodingCompletes() async throws {
        let rowCount = 10_001
        let rows = (0..<rowCount).map {
            WorkspaceDatabaseDataRow(
                id: $0,
                values: [.text(String($0))]
            )
        }
        let source = TestGridDataSource(
            columns: [(TestGridDataSource.idIdentifier, 0)],
            rows: rows
        )
        let tableView = makeTable(source: source, columnNames: ["value"])
        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 0, column: 1),
            active: WorkspaceGridCoordinate(row: rowCount - 1, column: 1)
        )

        let duration = ContinuousClock().measure {
            tableView.copy(nil)
        }

        #expect(duration < .milliseconds(100))
        for _ in 0..<200 {
            if tableView.copyPasteboard.string(forType: .string)?
                .hasSuffix("10000") == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            tableView.copyPasteboard.string(forType: .string)?
                .hasSuffix("10000") == true
        )
        withExtendedLifetime(source) {}
    }

    private func makeTable()
        -> (WorkspaceDirectDrawTableView, TestGridDataSource)
    {
        let source = TestGridDataSource(
            columns: [
                (TestGridDataSource.idIdentifier, 0),
                (TestGridDataSource.nameIdentifier, 1),
            ],
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("1"), .text("Alice")]
                ),
                WorkspaceDatabaseDataRow(
                    id: 1,
                    values: [.text("2"), .text("Bob")]
                ),
            ]
        )
        return (
            makeTable(source: source, columnNames: ["id", "name"]),
            source
        )
    }

    private func makeTable(
        source: TestGridDataSource,
        columnNames: [String]
    ) -> WorkspaceDirectDrawTableView {
        let tableView = WorkspaceDirectDrawTableView()
        tableView.dataSource = source
        tableView.workspaceDataSource = source
        tableView.rowNumberIdentifier = TestGridDataSource.rowIdentifier
        tableView.copyPasteboard = NSPasteboard(
            name: NSPasteboard.Name(UUID().uuidString)
        )

        let rowColumn = NSTableColumn(
            identifier: TestGridDataSource.rowIdentifier
        )
        rowColumn.title = "#"
        tableView.addTableColumn(rowColumn)
        for (offset, pair) in source.columns.enumerated() {
            let column = NSTableColumn(identifier: pair.0)
            column.title = columnNames[offset]
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
        return tableView
    }
}

@MainActor
private final class TestGridDataSource: NSObject,
    NSTableViewDataSource, WorkspaceDirectDrawTableViewDataSource
{
    static let rowIdentifier = NSUserInterfaceItemIdentifier("test.row")
    static let idIdentifier = NSUserInterfaceItemIdentifier("test.id")
    static let nameIdentifier = NSUserInterfaceItemIdentifier("test.name")

    let columns: [(NSUserInterfaceItemIdentifier, Int)]
    private let rows: [WorkspaceDatabaseDataRow]

    init(
        columns: [(NSUserInterfaceItemIdentifier, Int)],
        rows: [WorkspaceDatabaseDataRow]
    ) {
        self.columns = columns
        self.rows = rows
    }

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { rows.count }
    }

    func workspaceTableView(
        _ tableView: WorkspaceDirectDrawTableView,
        dataColumnIndexFor identifier: NSUserInterfaceItemIdentifier
    ) -> Int? {
        columns.first(where: { $0.0 == identifier })?.1
    }

    func workspaceTableViewCopySnapshot(
        _ tableView: WorkspaceDirectDrawTableView
    ) -> WorkspaceGridCopySnapshot {
        let rows = rows
        return WorkspaceGridCopySnapshot(rowAt: { rows[$0] })
    }
}
