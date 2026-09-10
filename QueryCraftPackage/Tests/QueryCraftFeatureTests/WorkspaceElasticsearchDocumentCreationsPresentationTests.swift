import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchDocumentCreationsPresentationTests {
    @Test(arguments: [true, false])
    func creationAcknowledgementsStayVisibleUntilPageAndDraftsAreReady(succeeds: Bool) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let names = ["_id", "_index", "_routing", "name", "count", "enabled", "tags"]
            let columns = names.enumerated().map { WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element) }
            func loadedRow(_ index: Int) -> WorkspaceDatabaseDataRow {
                .init(id: index, values: [.text("doc-\(index)"), .text("logs-000001"), .null,
                    .text("name-\(index)"), .text(String(index)), .text("true"), .text("[]")])
            }
            let page = WorkspaceDatabaseDataPage(columns: columns, rows: (0..<2).map(loadedRow),
                offset: 0, limit: 200, hasNextPage: false)
            let request = WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(
                selection: .init(databaseName: "Elasticsearch", objectName: "logs-write", kind: .elasticsearchAlias),
                pageColumns: columns)
            var editor = WorkspaceDatabaseDataRowInsertEditorState()
            editor.present(request)
            editor.appendRow()
            editor.appendRow()
            let ids = editor.rowIDs
            for (index, id) in ids.enumerated() {
                editor.update(rowID: id, columnName: "name", draft: .init(mode: .value, text: "draft-\(index)"))
            }
            let presentation = try #require(WorkspaceElasticsearchCreationTablePresentation(
                dataState: .loaded(page), countState: .loaded(2), rowInsertEditor: editor,
                selectedRowIndexes: [4]))
            let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in },
                rowInsertEditor: editor, selectedRowIndexes: [4], rowActionKind: .elasticsearchDocument)
            let scroll = coordinator.makeScrollView()
            scroll.appearance = NSAppearance(named: appearance)
            scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
            scroll.layoutSubtreeIfNeeded()
            let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
            table.scrollColumnToVisible(5)
            table.scrollRowToVisible(4)
            let origin = scroll.contentView.bounds.origin
            let widths = table.tableColumns.map(\.width)
            let acknowledgedCount = succeeds ? 3 : 1
            for acknowledged in 1...acknowledgedCount {
                editor.retainDraftRows(Set(ids.dropFirst(acknowledged)))
                coordinator.update(page: try #require(presentation.dataState.page), isFetching: true,
                    sortData: { _ in }, rowInsertEditor: presentation.rowInsertEditor,
                    selectedRowIndexes: presentation.selectedRowIndexes, rowActionKind: .elasticsearchDocument)
                #expect(table.numberOfRows == 5)
                #expect(table.gridSelection.rows == 4...4)
                #expect(presentation.rowInsertEditor.rowIDs == ids)
                #expect(presentation.rowInsertEditor.isSubmitting)
                #expect(presentation.countState == .loaded(2))
                #expect(scroll.contentView.bounds.origin == origin)
                for row in 2...4 {
                    let view = try #require(table.rowView(atRow: row, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
                    #expect(view.pendingPresentationBackgroundColor != nil)
                }
            }
            let refreshed = WorkspaceDatabaseDataPage(columns: columns, rows: (0..<(2 + acknowledgedCount)).map(loadedRow),
                offset: 0, limit: 200, hasNextPage: false)
            if succeeds { editor.dismiss() } else { editor.setSubmitting(false) }
            // This is the single publication after the page reload completes, including a partial failure.
            coordinator.update(page: refreshed, isFetching: false, sortData: { _ in }, rowInsertEditor: editor,
                selectedRowIndexes: [4], rowActionKind: .elasticsearchDocument)
            #expect(table.numberOfRows == 5)
            #expect(editor.rowCount == 3 - acknowledgedCount)
            #expect(scroll.contentView.bounds.origin == origin)
            #expect(table.tableColumns.map(\.width) == widths)
            for row in 2...4 {
                let view = try #require(table.rowView(atRow: row, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
                #expect((view.pendingPresentationBackgroundColor != nil) == (row >= refreshed.rowCount))
            }
        }
    }

    @Test func multipleDraftRowsRetainValuesColorsAndViewport() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let names = ["_id", "_index", "_routing", "name", "count", "enabled", "tags"]
            let columns = names.enumerated().map { WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element) }
            let page = WorkspaceDatabaseDataPage(columns: columns,
                rows: [.init(id: 0, values: [.text("existing"), .text("logs-000001"), .null,
                    .text("existing"), .text("1"), .text("true"), .text("[]")])],
                offset: 0, limit: 200, hasNextPage: false)
            let request = WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(
                selection: .init(databaseName: "Elasticsearch", objectName: "logs-write", kind: .elasticsearchAlias), pageColumns: columns)
            var editor = WorkspaceDatabaseDataRowInsertEditorState()
            editor.present(request)
            editor.appendRow()
            editor.appendRow()
            let ids = editor.rowIDs
            for (index, id) in ids.enumerated() {
                editor.update(rowID: id, columnName: "_id", draft: .init(mode: .value, text: "draft-\(index)"))
                editor.update(rowID: id, columnName: "count", draft: .init(mode: .value, text: String(11 + index)))
            }
            let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in },
                rowInsertEditor: editor, selectedRowIndexes: [1], rowActionKind: .elasticsearchDocument)
            let scroll = coordinator.makeScrollView()
            scroll.appearance = NSAppearance(named: appearance)
            scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
            scroll.layoutSubtreeIfNeeded()
            let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
            table.scrollColumnToVisible(5)
            let origin = scroll.contentView.bounds.origin.x
            let widths = table.tableColumns.map(\.width)
            #expect(table.numberOfRows == 4)
            for index in 1...3 {
                let view = try #require(table.rowView(atRow: index, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
                #expect((view.accessibilityValue() as? String)?.contains("draft-\(index - 1)") == true)
                #expect(view.pendingPresentationBackgroundColor != nil)
            }
            editor.setSubmitting(true)
            editor.retainDraftRows(Set(ids.dropFirst()))
            coordinator.update(page: page, isFetching: false, sortData: { _ in }, rowInsertEditor: editor,
                selectedRowIndexes: [1], rowActionKind: .elasticsearchDocument)
            #expect(table.numberOfRows == 3)
            #expect(editor.rowIDs == Array(ids.dropFirst()))
            #expect(editor.draft(rowID: ids[1], for: "count")?.text == "12")
            #expect(scroll.contentView.bounds.origin.x == origin)
            #expect(table.tableColumns.map(\.width) == widths)
            editor.dismiss()
            coordinator.update(page: page, isFetching: false, sortData: { _ in }, rowInsertEditor: editor,
                rowActionKind: .elasticsearchDocument)
            #expect(table.numberOfRows == 1)
            #expect(scroll.contentView.bounds.origin.x == origin)
            #expect(table.tableColumns.map(\.width) == widths)
        }
    }

    @Test func existingDraftDiscardAndNativeShortcutsRemainAvailable() throws {
        try WorkspaceDatabaseDataPendingPresentationTests().elasticsearchCreationDraftCanBeDiscardedFromItsRowMenu()
        WorkspaceDatabaseDataPendingPresentationTests().textEditorKeepsDeleteKeyForTextEditing()
    }
}
