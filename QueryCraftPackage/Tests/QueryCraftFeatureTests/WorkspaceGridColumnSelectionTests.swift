import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceGridColumnSelectionTests {
    @Test func plainClickSelectsEveryRowInClickedColumn() throws {
        let tableView = makeTableView(rowCount: 5)
        tableView.selectGridColumn(2)
        let selection = try #require(tableView.gridSelection.active)
        #expect(tableView.gridSelection.anchor?.row == 0)
        #expect(selection.row == 4)
        #expect(tableView.gridSelection.anchor?.column == 2)
        #expect(selection.column == 2)
        #expect(tableView.gridSelection.cellCount == 5)
    }

    @Test func shiftClickExtendsAcrossFullColumns() throws {
        let tableView = makeTableView(rowCount: 3)
        tableView.selectGridColumn(1)
        tableView.selectGridColumn(3, extending: true)
        #expect(tableView.gridSelection.anchor?.column == 1)
        #expect(tableView.gridSelection.active?.column == 3)
        #expect(tableView.gridSelection.anchor?.row == 0)
        #expect(tableView.gridSelection.active?.row == 2)
        #expect(tableView.gridSelection.cellCount == 3 * 3)
    }

    @Test func rowNumberColumnSelectionIsIgnored() {
        let tableView = makeTableView(rowCount: 3)
        tableView.selectGridColumn(0)
        #expect(tableView.gridSelection.isEmpty)
    }

    private func makeTableView(
        rowCount: Int
    ) -> WorkspaceDirectDrawTableView {
        let tableView = WorkspaceDirectDrawTableView()
        tableView.rowNumberIdentifier = NSUserInterfaceItemIdentifier(
            "rowNumber"
        )
        let rowNumberColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("rowNumber")
        )
        tableView.addTableColumn(rowNumberColumn)
        for index in 1...3 {
            tableView.addTableColumn(NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("data.\(index)")
            ))
        }
        tableView.dataSource = StubDataSource(rowCount: rowCount)
        return tableView
    }
}

@MainActor
private final class StubDataSource: NSObject, NSTableViewDataSource {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }
}
