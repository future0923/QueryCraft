import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceTimestampDisplayTests {
    private let raw = "1704164645000"
    private let column = WorkspaceDatabaseDataColumn(id: 0, name: "timestamp", type: "BIGINT")

    @Test
    func recognizesSQLKafkaAndElasticsearchTimestampColumns() {
        let formatter = WorkspaceTimestampDisplayFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        let columns = [
            column,
            WorkspaceDatabaseDataColumn(id: 0, name: "created_at", type: "bigint unsigned"),
            WorkspaceDatabaseDataColumn(id: 0, name: "createTime", type: "INTEGER"),
            WorkspaceDatabaseDataColumn(id: 0, name: "@timestamp", type: "date"),
            WorkspaceDatabaseDataColumn(id: 0, name: "updatedAt", type: "long"),
            WorkspaceDatabaseDataColumn(id: 0, name: "alias", type: "BIGINT", origin: .init(
                tableName: "events", columnName: "created_at"
            )),
        ]
        for column in columns {
            #expect(formatter.timestamp(raw, column: column) == "2024-01-02 03:04:05")
            #expect(formatter.timestamp("1704164645", column: column) == "2024-01-02 03:04:05")
        }
    }

    @Test
    func usesTheChosenTimezoneWithoutChangingMilliseconds() {
        let formatter = WorkspaceTimestampDisplayFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(formatter.timestamp("1704164645987", column: column) == "2024-01-02 11:04:05")
        #expect(formatter.timestamp(raw, column: column, mode: .raw) == nil)
    }

    @Test
    func doesNotMistakeIDsOffsetsDurationsOrJSONForDates() {
        let formatter = WorkspaceTimestampDisplayFormatter()
        for name in ["id", "offset", "partition", "phone", "timeout", "format", "duration"] {
            #expect(formatter.timestamp(raw, column: .init(id: 0, name: name, type: "BIGINT")) == nil)
        }
        for value in ["", "0", "-1", "1234", "20260102030405", "1704164645000000",
                      "NaN", "Infinity", "1.704164645e9", "1704164645.5", " 1704164645",
                      "+1704164645", "١٧٠٤١٦٤٦٤٥", "9223372036854775808", "{\"time\":1704164645}"] {
            #expect(formatter.timestamp(value, column: column) == nil)
        }
        #expect(formatter.timestamp(raw, column: .init(id: 0, name: "timestamp", type: "TEXT")) == nil)
    }

    @Test
    func explicitFormatsSupportEpochAndHistoricalDatesWithSafeFallbacks() {
        let formatter = WorkspaceTimestampDisplayFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        let unnamed = WorkspaceDatabaseDataColumn(id: 0, name: "value")
        #expect(formatter.timestamp("0", column: unnamed, mode: .seconds) == "1970-01-01 00:00:00")
        #expect(formatter.timestamp("-1000", column: unnamed, mode: .milliseconds) == "1969-12-31 23:59:59")
        #expect(formatter.timestamp(raw, column: unnamed, mode: .milliseconds) == "2024-01-02 03:04:05")
        #expect(formatter.timestamp(raw, column: unnamed, mode: .seconds) == nil)
        #expect(formatter.timestamp("253402300800", column: unnamed, mode: .seconds) == nil)
        #expect(formatter.timestamp(String(repeating: "1", count: 100_000), column: unnamed, mode: .seconds) == nil)
    }

    @Test
    func preservesNullEmptyBinaryAndAlreadyFormattedCells() {
        let formatter = WorkspaceTimestampDisplayFormatter()
        for cell: WorkspaceDatabaseDataCell in [.null, .text(""), .binary(byteCount: 8), .text("2024-01-02T03:04:05Z")] {
            #expect(formatter.preview(cell, column: column, nullDisplayText: "(null)",
                                      emptyStringDisplayText: "(empty)", maximumCharacterCount: 50)
                == cell.gridPreviewText(nullDisplayText: "(null)", emptyStringDisplayText: "(empty)", maximumCharacterCount: 50))
        }
    }

    @Test
    func reservesTimestampWidthBeforeRowsArrive() {
        let empty = WorkspaceGridColumnSizing.automaticWidths(
            columns: [column], rowCount: 0, maximumConsideredRows: nil, rowAt: { _ in nil }
        )
        let loaded = WorkspaceGridColumnSizing.automaticWidths(
            columns: [column], rowCount: 1, maximumConsideredRows: nil,
            rowAt: { _ in .init(id: 0, values: [.text(raw)]) }
        )
        #expect(empty == loaded)
        #expect(empty[0, default: 0] > 140)
    }

    @Test
    func sharedGridSizesAndAnnouncesFormattedValuesButCopiesRawValues() throws {
        let coordinator = makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        let displayed = table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50)
        #expect(displayed.count == 19)
        let formattedWidth = table.tableColumns[1].width
        #expect(formattedWidth >= (displayed as NSString).size(withAttributes: [.font: WorkspaceGridMetrics.cellFont]).width)
        let rowView = WorkspaceDatabaseDataRowView()
        rowView.configure(tableView: table, dataRow: .init(id: 0, values: [.text(raw)]), rowIndex: 0,
                          columnIndexes: [table.tableColumns[1].identifier: 0], rowNumberIdentifier: table.tableColumns[0].identifier)
        #expect(rowView.accessibilityValue() as? String == displayed)

        table.copyPasteboard = NSPasteboard(name: .init(UUID().uuidString))
        defer { table.copyPasteboard.releaseGlobally() }
        table.selectGridRange(anchor: .init(row: 0, column: 1), active: .init(row: 0, column: 1))
        table.copy(nil)
        #expect(table.copyPasteboard.string(forType: .string) == raw)
        #expect(coordinator.workspaceTableViewCopySnapshot(table).rowAt(0)?.values == [.text(raw), .text(raw)])
        #expect(table.dataExportSnapshot()?.rowAt(0)?.values == [.text(raw), .text(raw)])

        table.tableColumns[2].width = 350
        table.setTimestampDisplayMode(.raw, dataColumnIndex: 0)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50) == raw)
        #expect(table.tableColumns[1].width < formattedWidth)
        #expect(table.tableColumns[2].width == 350)
    }

    @Test
    func headerMenuTracksColumnIdentityAfterReorderingAndResetsBetweenObjects() throws {
        let coordinator = makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        let timestampIdentifier = table.tableColumns[1].identifier
        table.moveColumn(1, toColumn: 2)
        let menu = try #require(table.timestampDisplayMenu(for: timestampIdentifier)?.submenu)
        let rawItem = try #require(menu.items.first { $0.tag == WorkspaceTimestampDisplayMode.raw.rawValue })
        menu.update()
        #expect(rawItem.isEnabled)
        _ = NSApp.sendAction(try #require(rawItem.action), to: rawItem.target, from: rawItem)
        #expect(table.timestampDisplayModes[0] == .raw)
        #expect(table.timestampDisplayModes[1] == nil)
        coordinator.update(page: makePage(), isFetching: false, sortData: { _ in })
        #expect(table.timestampDisplayModes[0] == .raw)
        coordinator.update(page: makePage(), isFetching: false, exportFileName: "another-topic", sortData: { _ in })
        #expect(table.timestampDisplayModes.isEmpty)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50).count == 19)
    }

    @Test
    func tableSettingUpdatesAnUnchangedPageAndPreservesColumnFormats() throws {
        let page = makePage()
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page, isFetching: false, formatsTimestamps: false, sortData: { _ in }
        )
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50) == raw)
        let rawWidth = table.tableColumns[1].width
        coordinator.update(page: page, isFetching: false, formatsTimestamps: true, sortData: { _ in })
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50).count == 19)
        #expect(table.tableColumns[1].width > rawWidth)
        table.setTimestampDisplayMode(.milliseconds, dataColumnIndex: 1)
        coordinator.update(page: page, isFetching: false, formatsTimestamps: false, sortData: { _ in })
        for index in 0...1 {
            #expect(table.cellPreview(.text(raw), dataColumnIndex: index, maximumCharacterCount: 50) == raw)
        }
        let menu = try #require(table.timestampDisplayMenu(for: table.tableColumns[1].identifier)?.submenu)
        menu.update()
        #expect(menu.items.allSatisfy { !$0.isEnabled })
        coordinator.update(page: page, isFetching: false, formatsTimestamps: true, sortData: { _ in })
        #expect(table.timestampDisplayModes[1] == .milliseconds)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 1, maximumCharacterCount: 50).count == 19)
        #expect(table.dataExportSnapshot()?.rowAt(0)?.values == [.text(raw), .text(raw)])
    }

    @Test
    func queryGridResetsOverridesForANewResult() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([.init(id: 0, values: [.text(raw)])])
        let page = WorkspaceQueryResultPage(columns: [column], store: store, rowCount: 1)
        let coordinator = WorkspaceQueryResultTableCoordinator(page: page)
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50).count == 19)
        coordinator.update(page: page, formatsTimestamps: false)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50) == raw)
        coordinator.update(page: page, formatsTimestamps: true)
        #expect(table.cellPreview(.text(raw), dataColumnIndex: 0, maximumCharacterCount: 50).count == 19)
        table.setTimestampDisplayMode(.raw, dataColumnIndex: 0)
        coordinator.update(page: .init(columns: [column], store: store, rowCount: 1))
        #expect(table.timestampDisplayModes[0] == .raw)
        let secondStore = try WorkspaceQueryResultStore(temporary: false)
        try await secondStore.append([.init(id: 0, values: [.text(raw)])])
        coordinator.update(page: .init(columns: [column], store: secondStore, rowCount: 1))
        #expect(table.timestampDisplayModes.isEmpty)
    }

    @Test
    func sqlEditingAndUpdateBindingsKeepTheOriginalTimestamp() throws {
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "id", type: "BIGINT"),
                       WorkspaceDatabaseDataColumn(id: 1, name: "created_at", type: "BIGINT")]
        let row = WorkspaceDatabaseDataRow(id: 0, values: [.text("1"), .text(raw)])
        let target = WorkspaceDatabaseDataCellEditTarget(rowIndex: 0, dataColumnIndex: 1, columns: columns, row: row)
        let selection = WorkspaceDatabaseObjectSelection(databaseName: "test", objectName: "events", kind: .table)
        let details = WorkspaceDatabaseObjectDetails(columns: columns.map {
            WorkspaceDatabaseColumn(name: $0.name, type: "BIGINT", collation: nil, isNullable: false,
                                    key: $0.id == 0 ? "PRI" : "", defaultValue: nil, extra: "", comment: "")
        }, ddl: "")
        let context = try WorkspaceLoadedDataCellEditing.inlineContext(selection: selection, target: target,
                                                                       details: details, pendingUpdates: [])
        #expect(context.initialText == raw)
        let request = try WorkspaceDatabaseDataCellEditRequest.make(selection: selection, target: target, details: details)
        let update = try request.makeUpdate(text: "1704164645987", usesNull: false)
        #expect(update.originalValue == .text(raw))
        #expect(try MySQLWorkspaceDataCellUpdateStatement.make(update: update).bindings == [.text("1704164645987"), .text("1")])
    }

    @Test
    func elasticsearchEditingKeepsNumericJSON() async throws {
        let editor = WorkspaceElasticsearchDocumentCellEditor()
        let source = Data("{\"timestamp\":\(raw)}".utf8)
        let initial = try await editor.initialValue(sourceJSON: source, fieldName: "timestamp")
        #expect(initial.text == raw)
        let json = try await editor.replacingFields(in: source, edits: ["timestamp": .text("1704164645987")])
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: NSNumber])
        #expect(object["timestamp"]?.int64Value == 1_704_164_645_987)
    }

    private func makePage() -> WorkspaceDatabaseDataPage {
        .init(columns: [column, .init(id: 1, name: "offset", type: "BIGINT")],
              rows: [.init(id: 0, values: [.text(raw), .text(raw)])], offset: 0, limit: 200, hasNextPage: false)
    }

    private func makeCoordinator() -> WorkspaceDatabaseDataTableCoordinator {
        .init(page: makePage(), isFetching: false, sortData: { _ in })
    }
}
