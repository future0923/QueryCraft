import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchCellChangesPresentationTests {
    @Test func multipleDocumentOverlaysSurviveSelectionAndDiscardInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let names = ["_id", "_index", "_routing", "count", "enabled", "numericText", "name", "profile"]
            let columns = names.enumerated().map { WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element) }
            let page = WorkspaceDatabaseDataPage(columns: columns, rows: (0..<3).map { row in
                WorkspaceDatabaseDataRow(id: row, values: [
                    .text("same-id"), .text("logs-000001"), .text("tenant-\(row)"),
                    .text("1"), .text("true"), .text("21"), .text("before"), .text("{}")
                ])
            }, offset: 0, limit: 200, hasNextPage: false)
            let changes = (0..<3).map { row in
                WorkspaceDatabaseInspectorPendingUpdate(update: WorkspaceDatabaseDataCellUpdate(
                    selection: WorkspaceDatabaseObjectSelection(databaseName: "Elasticsearch", objectName: "logs", kind: .elasticsearchAlias),
                    columnName: "name", originalValue: .text("before"), newValue: .text("after-\(row)"),
                    primaryKey: [
                        .init(columnName: "_id", value: .text("same-id")),
                        .init(columnName: "_index", value: .text("logs-000001")),
                        .init(columnName: "_routing", value: .text("tenant-\(row)"))
                    ]
                ))
            }
            let coordinator = WorkspaceDatabaseDataTableCoordinator(
                page: page, isFetching: false, sortData: { _ in },
                selectedRowIndexes: [0], rowActionKind: .elasticsearchDocument
            )
            let scroll = coordinator.makeScrollView()
            scroll.appearance = NSAppearance(named: appearance)
            scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 320)
            scroll.layoutSubtreeIfNeeded()
            let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
            let coordinate = WorkspaceGridCoordinate(row: 0, column: 6)
            table.selectGridRange(anchor: coordinate, active: coordinate)
            table.scrollColumnToVisible(6)
            let origin = scroll.contentView.bounds.origin.x
            let widths = table.tableColumns.map(\.width)
            #expect(origin > 0)
            for row in 0..<3 {
                coordinator.update(page: page, isFetching: false, sortData: { _ in },
                    pendingLoadedUpdates: changes, selectedRowIndexes: IndexSet(integer: row),
                    rowActionKind: .elasticsearchDocument)
                for index in 0..<3 {
                    let view = try #require(table.rowView(atRow: index, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
                    #expect((view.accessibilityValue() as? String)?.contains("after-\(index)") == true)
                    #expect(view.pendingUpdateBackgroundColor(at: 6) != nil)
                    #expect(view.pendingUpdateBackgroundColor(at: 3) == nil)
                }
                #expect(scroll.contentView.bounds.origin.x == origin)
                #expect(table.tableColumns.map(\.width) == widths)
            }
            // Partial success clears only the acknowledged row's overlay.
            coordinator.update(page: page, isFetching: false, sortData: { _ in },
                pendingLoadedUpdates: Array(changes.dropFirst()), selectedRowIndexes: [2],
                rowActionKind: .elasticsearchDocument)
            let first = try #require(table.rowView(atRow: 0, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
            #expect(first.pendingUpdateBackgroundColor(at: 6) == nil)
            coordinator.update(page: page, isFetching: false, sortData: { _ in },
                selectedRowIndexes: [2], rowActionKind: .elasticsearchDocument)
            for index in 0..<3 {
                let view = try #require(table.rowView(atRow: index, makeIfNecessary: true) as? WorkspaceDatabaseDataRowView)
                #expect((view.accessibilityValue() as? String)?.contains("before") == true)
                #expect(view.pendingUpdateBackgroundColor(at: 6) == nil)
            }
            #expect(scroll.contentView.bounds.origin.x == origin)
            #expect(table.tableColumns.map(\.width) == widths)
            #expect(table.selectedDataRowIndexesForActions == [2])
            #expect(table.gridSelection.active?.column == 6)
        }
    }

    @Test func relationalCellUpdatesKeepExistingPresentation() throws {
        try WorkspaceDatabaseDataPendingPresentationTests().pendingCellColorsTrackMultipleUpdatesAndDiscard()
    }

    @Test func nativeTextEditorKeepsDeleteKeys() {
        WorkspaceDatabaseDataPendingPresentationTests().textEditorKeepsDeleteKeyForTextEditing()
    }

    @Test func discardDismissesTheActiveEditorWithoutRestagingOnFocusLoss() throws {
        let page = WorkspaceDatabaseDataPage(
            columns: [.init(id: 0, name: "name")],
            rows: [.init(id: 0, values: [.text("before")])],
            offset: 0, limit: 200, hasNextPage: false
        )
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in })
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        scroll.layoutSubtreeIfNeeded()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        let lifetime = WorkspaceDataCellEditingLifetime()
        let context = WorkspaceDatabaseDataCellInlineEditContext(
            rowIndex: 0, dataColumnIndex: 0, columnName: "name", initialText: "before",
            initialMutation: .value("before"), editingLifetime: lifetime, editingRevision: lifetime.revision
        )
        let editor = WorkspaceDataCellInlineEditor()
        var mutations: [WorkspaceDatabaseInspectorMutation] = []
        editor.begin(in: table, context: context, tableColumnIndex: 1, cellFont: .systemFont(ofSize: 12),
            update: { _, mutation in mutations.append(mutation) }, canEdit: { _, _ in true },
            beginEdit: { _, _ in }, redraw: { _ in })
        let field = try #require(table.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "after"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(mutations == [.value("after")])
        lifetime.finish(commit: false)
        #expect(!editor.isEditing)
        #expect(field.superview == nil)
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(mutations == [.value("after")])
        // A preparation from before Discard cannot reopen a stale editor.
        editor.begin(in: table, context: context, tableColumnIndex: 1, cellFont: .systemFont(ofSize: 12),
            update: { _, mutation in mutations.append(mutation) }, canEdit: { _, _ in true },
            beginEdit: { _, _ in }, redraw: { _ in })
        #expect(!editor.isEditing)
        #expect(table.subviews.compactMap { $0 as? NSTextField }.isEmpty)
    }
}
