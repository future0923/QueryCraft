import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceLongCellContentTests {
    @Test
    func detailAndClipboardUseFullValueDespiteBoundedPreviewAndReordering() throws {
        let text = String(repeating: "中🙂", count: 200_000) + "END-OF-VALUE"
        let page = WorkspaceDatabaseDataPage(columns: [
            WorkspaceDatabaseDataColumn(id: 0, name: "_id"),
            WorkspaceDatabaseDataColumn(id: 1, name: "payload")
        ], rows: [WorkspaceDatabaseDataRow(id: 0, values: [.text("1"), .text(text)])],
            offset: 0, limit: 1, hasNextPage: false)
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in })
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        table.copyPasteboard = NSPasteboard(name: .init("long-cell-" + UUID().uuidString))
        defer { table.copyPasteboard.releaseGlobally() }
        let originalColumn = try #require(table.tableColumns.firstIndex { $0.title == "payload" })
        #expect(table.fullCellText(row: 0, column: originalColumn) == text)
        table.moveColumn(originalColumn, toColumn: 1)
        #expect(table.fullCellText(row: 0, column: 1) == text)
        #expect(table.fullCellText(row: 0, column: 2) == nil)
        table.selectGridRange(anchor: .init(row: 0, column: 1), active: .init(row: 0, column: 1))
        table.copy(nil)
        #expect(table.copyPasteboard.string(forType: .string) == text)
        #expect(page.row(at: 0)?.value(at: 1).gridPreviewText(nullDisplayText: "NULL", maximumCharacterCount: 300).count == 303)
    }
}
