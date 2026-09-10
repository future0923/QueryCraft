import AppKit
import Testing
@testable import QueryCraftFeature

@Suite(.serialized) @MainActor
struct WorkspaceElasticsearchMappingInteractionTests {
    @Test func commandIAddsMappingFieldWhileRealGridOwnsFocus() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = WorkspaceDirectDrawTableView(frame: window.contentView!.bounds)
        window.contentView = table
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(table))
        var additions = 0
        let actions = WorkspaceDatabaseSchemaRowCommandActions(kind: .column, selectedID: nil, canAdd: true,
            canDuplicate: false, canDelete: false, add: { additions += 1 }, duplicate: { _ in }, delete: { _ in })
        let handler = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(actions: nil, filterPresentationActions: nil,
            objectDetailTabActions: nil, isSuspended: false, schemaActions: actions, handlesSchemaActionsInDataGrid: true)
        for characters in ["i", "中"] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 34))
            #expect(event.window?.firstResponder === table)
            #expect(handler.handle(event))
            await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        }
        #expect(additions == 2)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "中",
            charactersIgnoringModifiers: "中", isARepeat: false, keyCode: 34))
        handler.schemaActions = .init(kind: .column, selectedID: nil, canAdd: false,
            canDuplicate: false, canDelete: false, add: { additions += 1 }, duplicate: { _ in }, delete: { _ in })
        #expect(!handler.handle(event))
        handler.schemaActions = actions
        handler.isSuspended = true
        #expect(!handler.handle(event))
        handler.isSuspended = false
        handler.handlesSchemaActionsInDataGrid = false
        #expect(!handler.handle(event))
        #expect(additions == 2)
    }

    @Test func consoleMappingTargetPreservesNamesAndEncodesOnlyReservedCharacters() throws {
        for name in ["qc_mapping_ui_20260908", "logs-2026.09_01~a", "测试_索引", "logs%value"] {
            let source = WorkspaceElasticsearchMappingActionsView.emptyRequestSource(for: name)
            let request = try #require(ElasticsearchConsoleParser().parse(source).first).request
            #expect(request.method == .put)
            #expect(request.path.removingPercentEncoding == "/\(name)/_mapping")
            #expect(!request.path.contains("%5F"))
            let url = try #require(URL(string: request.path, relativeTo: URL(string: "http://localhost:9200")))
            #expect(url.path == "/\(name)/_mapping")
            #expect(url.query == nil)
            #expect(url.fragment == nil)
        }
    }

    @Test func mappingSizesFirstLoadedFieldsAndPreservesSubsequentManualWidths() throws {
        let columns = ["Field", "Type", "Indexed", "Searchable", "Aggregatable"].enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        let empty = WorkspaceDatabaseDataPage(columns: columns, rows: [], offset: 0, limit: 1, hasNextPage: false)
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: empty, isFetching: true, sortData: { _ in })
        coordinator.mappingActions = .init(changedColumns: [:], canEdit: { _, _ in false }, menuItems: { _ in [] })
        let scrollView = coordinator.makeScrollView()
        let table = try #require(scrollView.documentView as? WorkspaceDirectDrawTableView)
        let fieldColumn = table.tableColumns[1]
        let initialWidth = fieldColumn.width
        let loaded = WorkspaceDatabaseDataPage(columns: columns, rows: [.init(id: 0, values: [
            .text("profile.address.postalCode"), .text("keyword"), .text("Server Default"), .text("true"), .text("true")
        ])], offset: 0, limit: 1, hasNextPage: false)
        coordinator.update(page: loaded, isFetching: false, sortData: { _ in })
        #expect(table.gridSelection.active == nil)
        #expect(fieldColumn.width > initialWidth)
        let expected = WorkspaceGridColumnSizing.automaticWidths(columns: columns, rowCount: 1,
            maximumConsideredRows: nil, rowAt: loaded.row(at:))
        #expect(fieldColumn.width == expected[0])
        fieldColumn.width = 240
        let refreshed = WorkspaceDatabaseDataPage(columns: columns, rows: [.init(id: 0, values: [
            .text("profile.address.postalCode.keyword"), .text("keyword"), .text("Server Default"), .text("true"), .text("true")
        ])], offset: 0, limit: 1, hasNextPage: false)
        coordinator.update(page: refreshed, isFetching: false, sortData: { _ in })
        #expect(table.gridSelection.active == nil)
        #expect(fieldColumn.width == 240)
    }

    @Test func mappingShortcutsUsePhysicalKeysAndDisableExistingDeletion() async throws {
        let id = UUID()
        var added = 0
        var deleted = 0
        let actions = WorkspaceDatabaseSchemaRowCommandActions(kind: .column, selectedID: id, canAdd: true, canDuplicate: false, canDelete: false, add: { added += 1 }, duplicate: { _ in }, delete: { _ in deleted += 1 })
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(actions: nil, filterPresentationActions: nil, objectDetailTabActions: nil, isSuspended: false, schemaActions: actions)
        let add = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "中", charactersIgnoringModifiers: "中", isARepeat: false, keyCode: 34))
        #expect(coordinator.handle(add))
        for code: UInt16 in [51, 117] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            _ = coordinator.handle(event)
        }
        await withCheckedContinuation { continuation in RunLoop.main.perform { continuation.resume() } }
        #expect(added == 1)
        #expect(deleted == 0)
    }

    @Test func nativeMenuDisabledStateAndDirectDrawPresentation() async throws {
        let item = WorkspaceMappingMenuItem(title: AppCopy.current.text("移除新增字段", "Remove New Field"), enabled: false) {}
        #expect(!item.isEnabled)
        #expect(item.image == nil)
        let worker = WorkspaceMappingEditorWorker()
        let snapshot = try WorkspaceMappingCodec.snapshot(target: .init(resource: "logs", kind: .elasticsearchIndex), data: Data(#"{"logs":{"mappings":{"properties":{"name":{"type":"keyword"}}}}}"#.utf8))
        let original = try await worker.rows(snapshot)
        var rows = original
        rows[0].parameters["ignore_above"] = "512"
        let changed = try await worker.presentation(rows: rows, originals: original, capabilities: [])
        #expect(changed.page.columns.count == 5)
        #expect(changed.changedColumns[0] == [0, 1, 2])
        let discarded = try await worker.presentation(rows: original, originals: original, capabilities: [])
        #expect(discarded.changedColumns.isEmpty)
        let restored = try await worker.restoredRows(snapshot, previous: original)
        #expect(restored[0].id == original[0].id)
    }

    @Test func mappingControlsPreserveDefaultsAndOnlyNewFieldsAreInteractive() throws {
        var row = WorkspaceMappingEditorRow(id: UUID(), originalPath: nil, parentPath: [], container: "properties",
                                            name: "extra", type: "text", parameters: [:], hasConflict: false)
        let values = WorkspaceDatabaseDataRow(id: 0, values: [.text("extra"), .text("text"), .text(""), .text("true"), .text("false")])
        let controls = WorkspaceMappingGridActions.controls(row: row, values: values, canEdit: { $0 < 3 })
        guard case .options = controls[1], case .booleanIndicator(.mixed) = controls[2],
              case .booleanIndicator(.on) = controls[3], case .booleanIndicator(.off) = controls[4] else {
            Issue.record("Mapping controls must distinguish default, enabled and read-only capability values")
            return
        }
        #expect(WorkspaceMappingGridActions.nextIndexedValue(nil) == "true")
        #expect(WorkspaceMappingGridActions.nextIndexedValue("true") == "false")
        #expect(WorkspaceMappingGridActions.nextIndexedValue("false") == nil)
        row.type = "object"
        guard case .unavailable = WorkspaceMappingGridActions.controls(row: row, values: values, canEdit: { _ in false })[2] else {
            Issue.record("Object fields do not have an index toggle")
            return
        }
        let existing = WorkspaceMappingGridActions.controls(row: row, values: values, canEdit: { _ in false })
        #expect(existing[1] == nil)
    }

    @Test func mappingCheckboxClickUsesGridActionsWithoutPassiveCellViews() throws {
        let page = WorkspaceDatabaseDataPage(columns: ["Field", "Type", "Indexed", "Searchable", "Aggregatable"].enumerated().map {
            .init(id: $0.offset, name: $0.element)
        }, rows: [.init(id: 0, values: [.text("newField"), .text("text"), .text("Server Default"), .text("true"), .text("false")])],
            offset: 0, limit: 1, hasNextPage: false)
        var toggles = 0
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: page, isFetching: false, sortData: { _ in }, prepareCellEdit: { _ in nil })
        coordinator.mappingActions = .init(changedColumns: [:], canEdit: { _, column in column < 3 }, menuItems: { _ in [] },
            cellControls: { _ in [1: .options, 2: .booleanIndicator(.mixed), 3: .booleanIndicator(.on), 4: .booleanIndicator(.off)] },
            toggleIndexed: { _ in toggles += 1 })
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        #expect(table.singleClickCellHandler?(0, 3) == true)
        #expect(toggles == 1)
        #expect(table.singleClickCellHandler?(0, 4) == false)
        #expect(toggles == 1)
        // A Mapping header must not enter the data grid's pending-sort state.
        coordinator.tableView(table, didClick: table.tableColumns[1])
        #expect(table.singleClickCellHandler?(0, 3) == true)
        #expect(toggles == 2)
        let row = try #require(coordinator.tableView(table, rowViewForRow: 0))
        row.frame = NSRect(x: 0, y: 0, width: 600, height: 24)
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            row.appearance = NSAppearance(named: name)
            row.appearance?.performAsCurrentDrawingAppearance {
                let image = NSImage(size: row.bounds.size, flipped: true) { _ in
                    row.draw(row.bounds)
                    return true
                }
                #expect(image.tiffRepresentation != nil)
            }
            #expect(row.subviews.isEmpty)
        }
        #expect(coordinator.tableView(table, viewFor: table.tableColumns[2], row: 0) == nil)
    }
}
