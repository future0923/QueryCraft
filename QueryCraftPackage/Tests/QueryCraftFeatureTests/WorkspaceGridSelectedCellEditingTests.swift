import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceGridSelectedCellEditingTests {
    enum Source: CaseIterable { case table, query }

    @Test(arguments: Source.allCases)
    func typingAndPasteFillOnlyTheSelectedColumn(_ source: Source) async throws {
        let fixture = try await Fixture(source: source)
        fixture.selectNames()
        #expect(fixture.table.cellTypingHandler?(1, 2, "新值") == true)
        #expect(fixture.recorder.updates.map(\.columnName) == ["name", "name"])
        #expect(fixture.recorder.updates.map(\.newValue) == [.text("新值"), .text("新值")])
        fixture.recorder.updates.removeAll()
        fixture.clipboard("完整的粘贴内容 123")
        let item = NSMenuItem(title: "Paste", action: #selector(WorkspaceDirectDrawTableView.paste(_:)), keyEquivalent: "v")
        #expect(fixture.table.validateUserInterfaceItem(item))
        fixture.table.paste(nil)
        #expect(fixture.recorder.updates.map(\.newValue) == Array(repeating: .text("完整的粘贴内容 123"), count: 2))
        #expect(fixture.recorder.updates.map { $0.primaryKey.first?.value } == [.text("1"), .text("2")])
        #expect(fixture.recorder.insertCount == 0)
        #expect(fixture.table.gridSelection.cellCount == 2)
    }

    @Test(arguments: Source.allCases)
    func oneUnavailableTargetPreventsPartialChanges(_ source: Source) async throws {
        let fixture = try await Fixture(source: source, unavailableRow: 1)
        fixture.selectNames()
        #expect(fixture.table.cellTypingHandler?(1, 2, "x") == true)
        #expect(fixture.recorder.updates.isEmpty)
        fixture.clipboard("replacement")
        fixture.table.paste(nil)
        #expect(fixture.recorder.updates.isEmpty)
        #expect(fixture.recorder.insertCount == 0)
    }

    @Test(arguments: Source.allCases)
    func pendingDeletedRowPreventsPartialChanges(_ source: Source) async throws {
        let fixture = try await Fixture(source: source, deletedRows: [1])
        fixture.selectNames()
        fixture.clipboard("replacement")
        fixture.table.paste(nil)
        #expect(fixture.recorder.updates.isEmpty)
        #expect(fixture.recorder.insertCount == 0)
    }

    @Test(arguments: Source.allCases)
    func reorderingUsesPhysicalColumnAndSingleCellPasteDoesNotInsert(_ source: Source) async throws {
        let fixture = try await Fixture(source: source)
        fixture.table.moveColumn(2, toColumn: 1)
        fixture.table.selectGridRange(anchor: .init(row: 1, column: 1), active: .init(row: 1, column: 1))
        fixture.clipboard("NULL")
        fixture.table.paste(nil)
        #expect(fixture.recorder.updates.map(\.columnName) == ["name"])
        #expect(fixture.recorder.updates.map(\.newValue) == [.text("NULL")])
        #expect(fixture.recorder.updates.first?.primaryKey.first?.value == .text("2"))
        #expect(fixture.recorder.insertCount == 0)
    }

    @Test(arguments: Source.allCases)
    func internalNullIsPreservedAndNonNullableBatchIsRejected(_ source: Source) async throws {
        let fixture = try await Fixture(source: source)
        fixture.selectNames()
        let payload = WorkspaceGridClipboardPayload(columnNames: ["source_alias"], rows: [[.null]])
        fixture.table.copyPasteboard.setData(try JSONEncoder().encode(payload), forType: WorkspaceGridClipboardPayload.pasteboardType)
        fixture.table.paste(nil)
        #expect(fixture.recorder.updates.map(\.newValue) == [.null, .null])
        fixture.recorder.updates.removeAll()
        fixture.table.selectGridRange(anchor: .init(row: 0, column: 1), active: .init(row: 1, column: 1))
        fixture.table.paste(nil)
        #expect(fixture.recorder.updates.isEmpty)
    }

    @Test
    func existingTabularInsertPasteIsPreserved() async throws {
        let fixture = try await Fixture(source: .table)
        fixture.selectNames()
        fixture.clipboard("first\nsecond")
        fixture.table.paste(nil)
        #expect(fixture.recorder.insertCount == 1)
        #expect(fixture.recorder.updates.isEmpty)
    }

    @Test
    func scalarClipboardRetainsEmptyAndQuotedMultilineText() {
        #expect(WorkspaceGridSelectedCellEditing.pastedValue(.init(internalPayload: nil, tabSeparatedText: "")) == .value(""))
        #expect(WorkspaceGridSelectedCellEditing.pastedValue(.init(internalPayload: nil, tabSeparatedText: "\"a\nb\"")) == .value("a\nb"))
        #expect(WorkspaceGridSelectedCellEditing.pastedValue(.init(internalPayload: nil, tabSeparatedText: "a\tb")) == nil)
        #expect(WorkspaceGridSelectedCellEditing.pastedValue(.init(internalPayload: Data([0]), tabSeparatedText: "fallback")) == nil)
    }

    @MainActor
    private final class Recorder {
        var updates: [WorkspaceDatabaseDataCellUpdate] = []
        var insertCount = 0
    }

    @MainActor
    private final class Fixture {
        let owner: AnyObject
        let table: WorkspaceDirectDrawTableView
        let recorder = Recorder()

        init(source: Source, unavailableRow: Int? = nil, deletedRows: IndexSet = []) async throws {
            let columns = [
                WorkspaceDatabaseDataColumn(id: 0, name: "id", type: "int", origin: .init(databaseName: "app", tableName: "users", columnName: "id")),
                WorkspaceDatabaseDataColumn(id: 1, name: "label", type: "varchar", origin: .init(databaseName: "app", tableName: "users", columnName: "name")),
            ]
            let rows = [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("1"), .text("before-1")]),
                WorkspaceDatabaseDataRow(id: 1, values: [.text("2"), .text("before-2")]),
            ]
            let selection = WorkspaceDatabaseObjectSelection(databaseName: "app", objectName: "users", kind: .table)
            let details = WorkspaceDatabaseObjectDetails(columns: [
                .init(name: "id", type: "int", collation: nil, isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: ""),
                .init(name: "name", type: "varchar(255)", collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: ""),
            ], ddl: "")
            let prepare: (WorkspaceDatabaseDataCellEditTarget) -> WorkspaceDatabaseDataCellInlineEditContext? = { target in
                guard target.rowIndex != unavailableRow else { return nil }
                return try? WorkspaceLoadedDataCellEditing.inlineContext(selection: selection, target: target, details: details, pendingUpdates: [])
            }
            let recorder = recorder
            let update: (WorkspaceDatabaseDataCellInlineEditContext, WorkspaceDatabaseInspectorMutation) -> Void = { context, mutation in
                do {
                    let target = WorkspaceDatabaseDataCellEditTarget(rowIndex: context.rowIndex, dataColumnIndex: context.dataColumnIndex, columns: columns, row: rows[context.rowIndex])
                    let request = try WorkspaceDatabaseDataCellEditRequest.make(selection: selection, target: target, details: details)
                    recorder.updates.append(try WorkspaceLoadedDataCellEditing.update(request: request, mutation: mutation))
                } catch { Issue.record("Unexpected invalid mutation: \(error)") }
            }
            switch source {
            case .table:
                let coordinator = WorkspaceDatabaseDataTableCoordinator(
                    page: .init(columns: columns, rows: rows, offset: 0, limit: 200, hasNextPage: false),
                    isFetching: false, sortData: { _ in }, prepareCellEdit: prepare, updateCellEdit: update,
                    databaseColumns: details.columns, pendingDeleteRowIndexes: deletedRows,
                    pasteRows: { _, _, _ in recorder.insertCount += 1 })
                owner = coordinator
                table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
            case .query:
                let store = try WorkspaceQueryResultStore(temporary: false)
                try await store.append(rows)
                let coordinator = WorkspaceQueryResultTableCoordinator(
                    page: .init(columns: columns, store: store, rowCount: rows.count),
                    prepareCellEdit: prepare, updateCellEdit: update, pendingDeleteRowIndexes: deletedRows)
                owner = coordinator
                table = try #require(coordinator.makeScrollView().documentView as? WorkspaceDirectDrawTableView)
            }
            table.copyPasteboard = NSPasteboard(name: .init(UUID().uuidString))
        }

        func selectNames() {
            table.selectGridRange(anchor: .init(row: 0, column: 2), active: .init(row: 1, column: 2))
        }

        func clipboard(_ text: String) {
            table.copyPasteboard.clearContents()
            table.copyPasteboard.setString(text, forType: .string)
        }
    }
}
