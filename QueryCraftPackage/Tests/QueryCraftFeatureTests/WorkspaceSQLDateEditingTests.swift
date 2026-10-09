import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct WorkspaceSQLDateEditingTests {
    @Test(arguments: ["DATE", "datev2", "time", "time(6)", "datetime", "DATETIMEV2(6)", "timestamp(3)", "timestamp(6) without time zone", "timestamp with time zone", "timestamptz"])
    func recognizesSQLCalendarTypes(_ name: String) {
        #expect(WorkspaceSQLDateType(name) != nil)
    }

    @Test(arguments: ["varchar", "bigint", "date[]", "timetz", "year", "json", "DateTime64(9)", "datetime(7)"])
    func doesNotGuessCalendarTypesFromTextOrDurations(_ name: String) {
        #expect(WorkspaceSQLDateType(name) == nil)
    }

    @Test(arguments: ["0000-00-00", "2025-02-29", "2024-02-30", "2024-13-01", "2024-00-01", "infinity", "2024-01-01 BC", "2024-01-01\n"])
    func invalidAndSpecialDatesKeepManualEditing(_ text: String) throws {
        let type = try #require(WorkspaceSQLDateType("date"))
        #expect(type.parse(text) == nil)
        let leapDay = try #require(type.parse("2024-02-29"))
        #expect(type.string(for: leapDay) == "2024-02-29")
    }

    @Test(arguments: ["2026-10-09 23:59:58.000001", "2024-03-10 02:30:00", "2024-11-03T01:30:00.120000"])
    func wallClocksRoundTripWithoutDSTOrPrecisionChanges(_ text: String) throws {
        let type = try #require(WorkspaceSQLDateType("datetime(6)"))
        let value = try #require(type.parse(text))
        #expect(type.string(for: value) == text)
    }

    @Test
    func timeOnlyValuesRoundTripWithoutShowingDateComponents() throws {
        let type = try #require(WorkspaceSQLDateType("time(6)"))
        #expect(!type.includesDate)
        #expect(type.includesTime)
        let value = try #require(type.parse("12:34:56.001200"))
        #expect(type.string(for: value) == "12:34:56.001200")
    }

    @Test(arguments: ["2026-10-09 00:05:00.123456+08", "2026-10-09T23:59:59.000010-03:30", "2026-10-09 12:00:00+05:30:45", "2026-10-09 12:00:00Z"])
    func timestampOffsetsRoundTripAndCalendarChangesPreserveThem(_ text: String) throws {
        let type = try #require(WorkspaceSQLDateType("timestamp(6) with time zone"))
        var value = try #require(type.parse(text))
        #expect(type.string(for: value) == text)
        value.date = try #require(WorkspaceSQLDateType.calendar.date(byAdding: .day, value: 1, to: value.date))
        #expect(type.string(for: value) == text.replacingOccurrences(of: "2026-10-09", with: "2026-10-10"))
    }

    @Test
    func rejectsSilentNormalizationsAndExcessPrecision() throws {
        let type = try #require(WorkspaceSQLDateType("datetime(3)"))
        #expect(type.parse("2026-10-09 24:00:00") == nil)
        #expect(type.parse("2026-10-09 12:60:00") == nil)
        #expect(type.parse("2026-10-09 12:00:60") == nil)
        #expect(type.parse("2026-10-09 12:00:00.1234") == nil)
        #expect(type.parse("2026-10-09 12:00:00+08") == nil)
        let zoned = try #require(WorkspaceSQLDateType("timestamptz"))
        #expect(zoned.parse("2026-10-09 12:00:00+08:99") == nil)
        var value = try #require(type.parse("2026-10-09 12:00:00.123"))
        value.fraction = "1e3"
        #expect(type.string(for: value) == nil)
    }

    @Test
    func defaultPrecisionFollowsSQLColumnDeclarations() throws {
        for name in ["datetime", "timestamp", "datetimev2"] {
            let type = try #require(WorkspaceSQLDateType(name))
            #expect(type.parse("2026-10-09 12:00:00") != nil)
            #expect(type.parse("2026-10-09 12:00:00.123456") == nil)
        }
        let postgresql = try #require(WorkspaceSQLDateType("timestamp without time zone"))
        #expect(postgresql.parse("2026-10-09 12:00:00.123456") != nil)
    }

    @Test
    func nowSeedUsesAnExplicitOffsetWithoutChangingWallClock() throws {
        let now = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 00:00:00 UTC
        let zone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let type = try #require(WorkspaceSQLDateType("timestamptz(6)"))
        #expect(type.string(for: type.seed(now: now, timeZone: zone)) == "2024-01-01 08:00:00.000000+08:00")
        let date = try #require(WorkspaceSQLDateType("date"))
        #expect(date.string(for: date.seed(now: now, timeZone: zone)) == "2024-01-01")
    }

    @Test
    func aliasedQueryEditingUsesResolvedSourceMetadata() throws {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "key", type: "int", origin: .init(databaseName: "app", tableName: "events", columnName: "id")),
            WorkspaceDatabaseDataColumn(id: 1, name: "display_date", type: "timestamp", origin: .init(databaseName: "app", tableName: "events", columnName: "created_at")),
        ]
        let context = try WorkspaceLoadedDataCellEditing.inlineContext(
            selection: .init(databaseName: "app", objectName: "events", kind: .table),
            target: .init(rowIndex: 0, dataColumnIndex: 1, columns: columns, row: .init(id: 0, values: [.text("1"), .null])),
            details: .init(columns: [column("id", type: "int", key: "PRI"), column("created_at", type: "timestamp(6) with time zone", nullable: true), column("display_date", type: "varchar")], ddl: ""),
            pendingUpdates: []
        )
        #expect(context.columnType == "timestamp(6) with time zone")
        #expect(context.isNullable)
        #expect(context.initialMutation == .null)
    }

    @MainActor @Test
    func dateButtonSharesCellBoundsAndCancelRemovesIt() throws {
        let page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "created_at", type: "date")], rows: [.init(id: 0, values: [.text("2024-02-29")])], offset: 0, limit: 200, hasNextPage: false)
        var mutations: [WorkspaceDatabaseInspectorMutation] = []
        let coordinator = WorkspaceDatabaseDataTableCoordinator(
            page: page, isFetching: false, sortData: { _ in },
            prepareCellEdit: { target in
                .init(rowIndex: target.rowIndex, dataColumnIndex: target.dataColumnIndex, columnName: "created_at", initialText: "2024-02-29", initialMutation: .value("2024-02-29"), columnType: "date")
            }, updateCellEdit: { _, mutation in mutations.append(mutation) }
        )
        let scroll = coordinator.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        scroll.layoutSubtreeIfNeeded()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        let originalHeight = table.rowHeight
        table.cellEditHandler?(0, 1)
        let text = try #require(table.subviews.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "dataCellInlineEditor" })
        let button = try #require(table.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "dataCellDatePickerButton" })
        #expect(text.frame.maxX == button.frame.minX)
        #expect(button.frame.maxX <= table.frameOfCell(atColumn: 1, row: 0).maxX)
        #expect(table.rowHeight == originalHeight)
        let editor = try #require(text.delegate as? WorkspaceDataCellInlineEditor)
        text.stringValue = "2026-10-09"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: text))
        #expect(mutations.last == .value("2026-10-09"))
        editor.cancel()
        #expect(mutations.last == .value("2024-02-29"))
        #expect(button.superview == nil)
        #expect(text.superview == nil)

        table.cellEditHandler?(0, 1)
        let mutationCount = mutations.count
        let replacement = WorkspaceDatabaseDataPage(columns: page.columns, rows: [], offset: 0, limit: 200, hasNextPage: false)
        coordinator.update(page: replacement, isFetching: false, sortData: { _ in })
        #expect(mutations.count == mutationCount)
        #expect(table.subviews.contains { $0.accessibilityIdentifier() == "dataCellDatePickerButton" } == false)
    }

    @MainActor @Test
    func newSQLRowsHaveDateButtonButElasticsearchDatesDoNot() throws {
        let selection = WorkspaceDatabaseObjectSelection(databaseName: "app", objectName: "events", kind: .table)
        let details = WorkspaceDatabaseObjectDetails(columns: [column("created_at", type: "datetime(6)", nullable: true)], ddl: "")
        var state = WorkspaceDatabaseDataRowInsertEditorState()
        state.present(try .make(selection: selection, details: details))
        let page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "created_at", type: "date")], rows: [], offset: 0, limit: 200, hasNextPage: false)
        for isElasticsearch in [false, true] {
            let coordinator = WorkspaceDatabaseDataTableCoordinator(
                page: page, isFetching: false, sortData: { _ in }, rowInsertEditor: state,
                rowActionKind: isElasticsearch ? .elasticsearchDocument : .tableRow
            )
            let scroll = coordinator.makeScrollView()
            let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
            table.cellEditHandler?(0, 1)
            #expect(table.subviews.contains { $0.accessibilityIdentifier() == "dataCellDatePickerButton" } == !isElasticsearch)
        }
    }

    @MainActor @Test
    func dateAndTimeEditorsApplyWallClockDraftWithFractionAndOffsetAndCancelDoesNotApply() throws {
        let type = try #require(WorkspaceSQLDateType("timestamptz(6)"))
        let controller = WorkspaceSQLDatePickerController(type: type, text: "2024-02-29 02:30:45.001200+08", isNullable: true)
        var mutations: [WorkspaceDatabaseInspectorMutation] = []
        var didCancel = false
        controller.apply = { mutations.append($0) }
        controller.cancel = { didCancel = true }
        let views = descendants(controller.view)
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateDateEditor" })
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateTimeEditor" })
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateNowButton" })
        #expect(!views.contains { $0.accessibilityLabel() == "小数秒" })
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateTimeEditor" })
        #expect(mutations.isEmpty)
        let apply = try #require(views.compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\r" })
        controller.perform(apply.action, with: apply)
        #expect(mutations == [.value("2024-02-29 02:30:45.001200+08")])
        controller.cancelOperation(nil)
        #expect(didCancel)
        #expect(mutations.count == 1)
        let null = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "NULL" })
        controller.perform(null.action, with: null)
        #expect(mutations.last == .null)
    }

    @MainActor @Test
    func dateEditorOffersDirectYearMonthDayInputs() throws {
        let type = try #require(WorkspaceSQLDateType("datetime"))
        let controller = WorkspaceSQLDatePickerController(type: type, text: "2024-02-29 02:30:45", isNullable: false)
        let views = descendants(controller.view)
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateDateEditor" })
    }

    @MainActor @Test
    func timeOnlyEditorOffersOnlyHourMinuteSecondInputs() throws {
        let type = try #require(WorkspaceSQLDateType("time(6)"))
        let controller = WorkspaceSQLDatePickerController(type: type, text: "12:34:56.001200", isNullable: true)
        let views = descendants(controller.view)
        #expect(!views.contains { $0.accessibilityIdentifier() == "sqlDateDateEditor" })
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateTimeEditor" })
        #expect(views.contains { $0.accessibilityIdentifier() == "sqlDateNowButton" })
    }

    @MainActor @Test
    func queryResultsOfferCalendarForResolvedDateAliasesAndCloseOnNewResult() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([.init(id: 0, values: [.text("1"), .text("2024-02-29")])])
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "id", type: "int", origin: .init(databaseName: "app", tableName: "events", columnName: "id")),
            WorkspaceDatabaseDataColumn(id: 1, name: "aliased_date", type: "date", origin: .init(databaseName: "app", tableName: "events", columnName: "created_at")),
        ]
        let page = WorkspaceQueryResultPage(columns: columns, store: store, rowCount: 1)
        let details = WorkspaceDatabaseObjectDetails(columns: [column("id", type: "int", key: "PRI"), column("created_at", type: "date")], ddl: "")
        var mutations: [WorkspaceDatabaseInspectorMutation] = []
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            prepareCellEdit: { target in
                try? WorkspaceLoadedDataCellEditing.inlineContext(selection: .init(databaseName: "app", objectName: "events", kind: .table), target: target, details: details, pendingUpdates: [])
            }, updateCellEdit: { _, mutation in mutations.append(mutation) }
        )
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? WorkspaceDirectDrawTableView)
        table.cellEditHandler?(0, 2)
        #expect(table.subviews.contains { $0.accessibilityIdentifier() == "dataCellDatePickerButton" })
        let newStore = try WorkspaceQueryResultStore(temporary: false)
        coordinator.update(page: .init(columns: columns, store: newStore, rowCount: 0))
        #expect(table.subviews.contains { $0.accessibilityIdentifier() == "dataCellDatePickerButton" } == false)
        #expect(mutations.isEmpty)
    }

    @MainActor @Test
    func popoverContentFitsAndRendersOffscreenInBothAppearances() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text, nullable) in [("date", "2024-02-29", false), ("timestamp(6) with time zone", "2026-10-09 12:34:56.001200+08:00", true), ("datetime(6)", "0000-00-00 00:00:00", true)] {
            for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let controller = WorkspaceSQLDatePickerController(type: try #require(WorkspaceSQLDateType(name)), text: text, isNullable: nullable)
                let drawingAppearance = try #require(NSAppearance(named: appearance))
                drawingAppearance.performAsCurrentDrawingAppearance { _ = controller.view }
                let view = controller.view
                view.appearance = drawingAppearance
                let size = view.fittingSize
                #expect(size.width == 320)
                #expect(size.height > 80 && size.height < 300)
                view.frame = NSRect(origin: .zero, size: size)
                let container = SQLDatePreviewBackground(frame: view.frame)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = drawingAppearance
                window.contentView = container
                container.addSubview(view)
                view.layoutSubtreeIfNeeded()
                #expect(descendants(view).contains { $0.accessibilityIdentifier() == "sqlDateDateEditor" })
                let buttons = descendants(view).compactMap { $0 as? NSButton }
                let nullButton = try #require(buttons.first { $0.title == "NULL" })
                #expect(nullButton.isEnabled == nullable)
                let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
                drawingAppearance.performAsCurrentDrawingAppearance {
                    container.cacheDisplay(in: container.bounds, to: bitmap)
                }
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                let prefix = name == "date" ? "date" : text.hasPrefix("0000") ? "special" : "timestamp"
                try data.write(to: directory.appendingPathComponent("sql-\(prefix)-picker-\(label).png"))
                window.contentView = nil
            }
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func column(_ name: String, type: String, nullable: Bool = false, key: String = "") -> WorkspaceDatabaseColumn {
        .init(name: name, type: type, collation: nil, isNullable: nullable, key: key, defaultValue: nil, extra: "", comment: "")
    }
}

@MainActor
private final class SQLDatePreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
