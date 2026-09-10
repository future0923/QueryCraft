import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchPastePresentationTests {
    @Test func gridPasteUsesNativeActionAndVisibleColumnOrderWithoutChangingGeometry() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let columns = ["_id", "name", "count", "enabled"].enumerated().map {
                WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
            }
            let page = WorkspaceDatabaseDataPage(columns: columns,
                rows: [.init(id: 0, values: [.text("existing"), .text("name"), .text("1"), .text("false")])],
                offset: 0, limit: 200, hasNextPage: false)
            let request = WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(
                selection: .init(databaseName: "Elasticsearch", objectName: "logs", kind: .elasticsearchIndex), pageColumns: columns)
            var editor = WorkspaceDatabaseDataRowInsertEditorState()
            editor.present(request)
            var receivedNames: [String] = []
            var receivedRowID: UUID?
            var receivedText: String?
            let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in },
                rowInsertEditor: editor, rowActionKind: .elasticsearchDocument,
                pasteRows: { content, names, rowID in
                    receivedText = content.tabSeparatedText
                    receivedNames = names
                    receivedRowID = rowID
                })
            let scroll = coordinator.makeScrollView()
            scroll.appearance = NSAppearance(named: appearance)
            scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
            scroll.layoutSubtreeIfNeeded()
            let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
            let clipboard = NSPasteboard.withUniqueName()
            defer { clipboard.releaseGlobally() }
            clipboard.setString("name\tcount\r\n中文\t1", forType: .string)
            table.copyPasteboard = clipboard
            table.moveColumn(3, toColumn: 2)
            table.selectGridRange(anchor: .init(row: 1, column: 2), active: .init(row: 1, column: 2))
            let widths = table.tableColumns.map(\.width)
            let origin = scroll.contentView.bounds.origin
            let item = NSMenuItem(title: "Paste", action: #selector(WorkspaceDirectDrawTableView.paste(_:)), keyEquivalent: "v")
            #expect(table.validateUserInterfaceItem(item))
            table.paste(nil)
            #expect(receivedNames == ["count", "name", "enabled"])
            #expect(receivedRowID == editor.rowIDs.first)
            #expect(receivedText == "name\tcount\r\n中文\t1")
            #expect(table.tableColumns.map(\.width) == widths)
            #expect(scroll.contentView.bounds.origin == origin)
            #expect(table.numberOfRows == 2)
            let row = try #require(table.rowView(atRow: 1, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
            #expect(row.pendingPresentationBackgroundColor != nil)
            #expect(row.subviews.isEmpty)
        }
    }
}
