import AppKit
import Foundation
import Testing
@testable import QueryCraftFeature

@Suite("Kafka JSON table", .timeLimit(.minutes(1)))
struct WorkspaceKafkaJSONTableTests {
    private let columns: [WorkspaceDatabaseDataColumn] = [
        .init(id: 0, name: "partition"), .init(id: 1, name: "offset"),
        .init(id: 2, name: "timestamp"), .init(id: 3, name: "key"),
        .init(id: 4, name: "headers"), .init(id: 5, name: "value")
    ]
    private func page(_ values: [WorkspaceDatabaseDataCell], firstID: Int = 0,
                      live: WorkspaceKafkaLivePageInfo? = nil) -> WorkspaceDatabaseDataPage {
        var page = WorkspaceDatabaseDataPage(columns: columns, rows: values.enumerated().map {
            .init(id: firstID + $0.offset, values: [.text("2"), .text(String(10 + firstID + $0.offset)),
                .text("1720000000123"), .text("key"), .text("header=one"), $0.element])
        }, offset: 200, limit: 100, hasNextPage: true)
        page.live = live
        return page
    }
    private func cell(_ page: WorkspaceDatabaseDataPage, _ name: String, row: Int = 0) throws -> WorkspaceDatabaseDataCell {
        let column = try #require(page.columns.first { $0.name == name })
        return try #require(page.row(at: row)).value(at: column.id)
    }

    @Test("Nested paths, exact numeric tokens, arrays and nulls coexist with original metadata")
    func nestedAndExactValues() async throws {
        let worker = WorkspaceKafkaJSONTableWorker()
        let raw = #"{"user":{"id":18446744073709551617,"name":"张三"},"amount":1.234567890123456789e+40,"enabled":true,"blank":"","missing":null,"items":[{"a":1}, 2],"empty":{}}"#
        let source = page([.text(raw)])
        let result = try await worker.project(source, context: "topic", schemaID: UUID())
        #expect(try cell(result, "partition") == .text("2"))
        #expect(try cell(result, "offset") == .text("10"))
        #expect(try cell(result, "timestamp") == .text("1720000000123"))
        #expect(try cell(result, "key") == .text("key"))
        #expect(try cell(result, "headers") == .text("header=one"))
        #expect(try cell(result, "value.user.id") == .text("18446744073709551617"))
        #expect(try cell(result, "value.user.name") == .text("张三"))
        #expect(try cell(result, "value.amount") == .text("1.234567890123456789e+40"))
        #expect(try cell(result, "value.enabled") == .text("true"))
        #expect(try cell(result, "value.blank") == .text(""))
        #expect(try cell(result, "value.missing") == .null)
        #expect(try cell(result, "value.items") == .text(#"[{"a":1}, 2]"#))
        #expect(try cell(result, "value.empty") == .text("{}"))
        #expect(try cell(result, "value") == .text(raw))
        #expect(source.rows[0].values[5] == .text(raw))
        #expect(result.rows[0].id == source.rows[0].id)
        #expect(result.offset == 200 && result.limit == 100 && result.hasNextPage)
        #expect(result.columns.map(\.id) == Array(result.columns.indices))
    }

    @Test("Literal dots, backslashes, empty names and metadata names cannot collide")
    func escapedPaths() async throws {
        let source = page([.text(#"{"user.id":"literal","user":{"id":"nested"},"":"empty","\\e":"escaped","partition":"payload","value":"payload value"}"#)])
        let result = try await WorkspaceKafkaJSONTableWorker().project(source, context: "topic", schemaID: UUID())
        #expect(try cell(result, #"value.user\.id"#) == .text("literal"))
        #expect(try cell(result, "value.user.id") == .text("nested"))
        #expect(try cell(result, #"value.\e"#) == .text("empty"))
        #expect(try cell(result, #"value.\\e"#) == .text("escaped"))
        #expect(try cell(result, "partition") == .text("2"))
        #expect(try cell(result, "value.partition") == .text("payload"))
        #expect(try cell(result, "value.value") == .text("payload value"))
        #expect(Set(result.columns.map(\.name)).count == result.columns.count)
    }

    @Test("Text, scalar JSON, binary, tombstones and malformed objects retain the full Value")
    func mixedRows() async throws {
        let values: [WorkspaceDatabaseDataCell] = [.text(#"{"a":1}"#), .text("plain text"),
            .text("[1,2]"), .text("true"), .null, .binary(byteCount: 10), .text("{}"),
            .text(#"{"a":01}"#), .text(#"{"a":1,"a":2}"#), .text(#"{"a":1,}"#),
            .text(#"{"a":1} trailing"#), .text(#"{"a":"\uD83D\uDE00"}"#)]
        let result = try await WorkspaceKafkaJSONTableWorker().project(page(values), context: "topic", schemaID: UUID())
        #expect(result.rowCount == values.count)
        for index in 1..<values.count - 1 {
            #expect(try cell(result, "value", row: index) == values[index])
            #expect(try cell(result, "value.a", row: index) == .null)
        }
        #expect(try cell(result, "value.a", row: values.count - 1) == .text("😀"))
    }

    @Test("Overlarge, deep and wide JSON uses raw Value instead of dropping fields")
    func boundedParsing() async throws {
        let wide = "{" + (0..<130).map { "\"f\($0)\":\($0)" }.joined(separator: ",") + "}"
        let deep = String(repeating: "{\"a\":", count: 40) + "1" + String(repeating: "}", count: 40)
        let huge = "{\"a\":\"" + String(repeating: "a", count: 1_048_576) + "\"}"
        let array = "{\"a\":[" + String(repeating: "0,", count: 4100) + "0]}"
        let values = [wide, deep, huge, array].map(WorkspaceDatabaseDataCell.text)
        let result = try await WorkspaceKafkaJSONTableWorker().project(page(values), context: "topic", schemaID: UUID())
        #expect(result.columns.count == columns.count)
        for index in values.indices { #expect(try cell(result, "value", row: index) == values[index]) }
    }

    @Test("Heterogeneous rows share a deterministic schema; missing fields are NULL")
    func heterogeneousSchema() async throws {
        let result = try await WorkspaceKafkaJSONTableWorker().project(
            page([.text(#"{"z":1,"a":2}"#), .text(#"{"b":3}"#)]), context: "topic", schemaID: UUID())
        #expect(result.columns.map(\.name).suffix(4) == ["value.a", "value.z", "value.b", "value"])
        #expect(try cell(result, "value.b") == .null)
        #expect(try cell(result, "value.z", row: 1) == .null)
    }

    @Test("Stable page revisions and refresh columns survive repeated presentation updates")
    func revisionAndRefresh() async throws {
        let worker = WorkspaceKafkaJSONTableWorker(), schema = UUID()
        let source = page([.text(#"{"a":1}"#)])
        let first = try await worker.project(source, context: "topic", schemaID: schema)
        let same = try await worker.project(source, context: "topic", schemaID: schema)
        #expect(first.revision == same.revision)
        let refreshed = try await worker.project(page([.text(#"{"a":2}"#)]), context: "topic", schemaID: schema)
        #expect(first.columns == refreshed.columns)
        #expect(try cell(refreshed, "value.a") == .text("2"))
        let other = try await worker.project(page([.text(#"{"b":3}"#)]), context: "other", schemaID: schema)
        #expect(!other.columns.contains { $0.name == "value.a" })
    }

    @Test("Live columns remain fixed; eviction and manual schema rebuild retain raw content")
    func liveSchemaAndEviction() async throws {
        let worker = WorkspaceKafkaJSONTableWorker(), schema = UUID(), stream = UUID()
        let first = try await worker.project(page([.text(#"{"a":1}"#)], live: .init(id: stream, firstSequence: 0, scrollRequest: 0)),
            context: "topic", schemaID: schema)
        let source = page([.text(#"{"a":2,"new":3}"#)], firstID: 1,
            live: .init(id: stream, firstSequence: 1, scrollRequest: 2))
        let next = try await worker.project(source, context: "topic", schemaID: schema)
        #expect(next.columns == first.columns)
        #expect(next.live == source.live)
        #expect(next.rows[0].id == 1)
        #expect(try cell(next, "value.a") == .text("2"))
        #expect(try cell(next, "value") == .text(#"{"a":2,"new":3}"#))
        let rebuilt = try await worker.project(source, context: "topic", schemaID: UUID())
        #expect(try cell(rebuilt, "value.new") == .text("3"))
        #expect(try cell(rebuilt, "value") == source.rows[0].values[5])
        let newStream = try await worker.project(page([.text(#"{"b":4}"#)], live: .init(id: UUID(), firstSequence: 0, scrollRequest: 0)),
            context: "topic", schemaID: schema)
        #expect(!newStream.columns.contains { $0.name == "value.a" })
    }

    @Test("An empty or plain-text first live batch does not prematurely freeze the schema")
    func liveFirstJSON() async throws {
        let worker = WorkspaceKafkaJSONTableWorker(), schema = UUID(), stream = UUID()
        _ = try await worker.project(page([], live: .init(id: stream, firstSequence: 0, scrollRequest: 0)), context: "topic", schemaID: schema)
        _ = try await worker.project(page([.text("plain")], live: .init(id: stream, firstSequence: 0, scrollRequest: 0)), context: "topic", schemaID: schema)
        let result = try await worker.project(page([.text(#"{"a":7}"#)], live: .init(id: stream, firstSequence: 0, scrollRequest: 0)), context: "topic", schemaID: schema)
        #expect(try cell(result, "value.a") == .text("7"))
    }

    @Test("A schema cap retains excess fields in the raw fallback")
    func cappedSchema() async throws {
        let source = page((0..<130).map { .text("{\"f\($0)\":\($0)}") })
        let result = try await WorkspaceKafkaJSONTableWorker().project(source, context: "topic", schemaID: UUID())
        #expect(result.columns.count == columns.count + 128)
        #expect(try cell(result, "value", row: 129) == source.rows[129].values[5])
    }

    @Test("The shared grid search, clipboard and CSV exporter use expanded fields")
    func sharedGridIntegration() async throws {
        let result = try await WorkspaceKafkaJSONTableWorker().project(page([.text(#"{"user":{"name":"Alice"}}"#)]),
            context: "topic", schemaID: UUID())
        let field = try #require(result.columns.first { $0.name == "value.user.name" })
        let matches = try await WorkspaceGridSearchWorker().search(source: .tablePage(result),
            request: .init(query: "Alice", dataColumnIndex: field.id, searchOperator: .contains, isCaseSensitive: false))
        #expect(matches.matches.count == 1)
        #expect(matches.matches.first?.dataColumnIndex == field.id)
        let copied = WorkspaceGridClipboardEncoder.encode(rows: .range(0...0),
            columns: [.init(name: field.name, dataIndex: field.id)], includesColumnNames: true,
            rowAt: { result.row(at: $0) })
        #expect(copied == "value.user.name\nAlice")
        let url = FileManager.default.temporaryDirectory.appending(path: "kafka-json-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = WorkspaceDataExportOptions()
        options.format = .csv
        options.csvIncludesUTF8BOM = false
        let request = WorkspaceDataExportRequest(columns: [.init(name: field.name, dataIndex: field.id)], options: options,
            estimatedRowCount: 1, worksheetName: "topic", source: WorkspaceSnapshotDataExportRowSource(rows: .range(0...0), rowAt: { result.row(at: $0) }))
        let exported = try await WorkspaceDataExporter().export(request, to: url)
        #expect(exported == 1)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("value.user.name\r\nAlice"))
    }

    @MainActor @Test("Projected rows copy the correct message location; the inspector retains exact raw JSON")
    func rawInspectorAndCopy() async throws {
        let raw = #"{ "partition": 999, "offset": 999, "a": 18446744073709551617 }"#
        let source = page([.text(raw)])
        let model = WorkspaceKafkaJSONTableModel()
        await model.load(source, selectionID: "topic", schemaID: UUID())
        let projected = try #require(model.page)
        let inspector = WorkspaceKafkaMessageInspectorContext(topic: "topic", page: model.sourcePage, selectedRowIndexes: IndexSet(integer: 0))
        #expect(inspector.row?.value(at: 5) == .text(raw))
        var copied: WorkspaceKafkaMessageReference?
        let action = WorkspaceKafkaMessageCopyAction(topic: "topic", open: { copied = $0 })
        let item = try #require(action.menuItem(row: projected.rows[0], columns: projected.columns))
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(copied == .init(topic: "topic", partition: 2, offset: 10))
    }

    @MainActor @Test("Refresh keeps paired data; another Topic never displays the previous Topic")
    func presentationStates() async throws {
        let model = WorkspaceKafkaJSONTableModel(), source = page([.text(#"{"a":1}"#)])
        await model.load(source, selectionID: "topic", schemaID: UUID())
        let revision = model.page?.revision
        #expect(model.state(for: .loaded(source), selectionID: "topic").page?.revision == revision)
        #expect(!model.state(for: .loaded(source), selectionID: "topic").isFetching)
        #expect(model.state(for: .fetching(source), selectionID: "topic").page?.revision == revision)
        let next = page([.text(#"{"a":2}"#)])
        #expect(model.state(for: .loaded(next), selectionID: "topic").isFetching)
        #expect(model.state(for: .loaded(next), selectionID: "other") == .loading)
        #expect(model.sourcePage?.revision == source.revision)
    }

    @Test("Cancellation does not replace the cached page")
    func cancellation() async throws {
        let worker = WorkspaceKafkaJSONTableWorker(), schema = UUID()
        let source = page([.text(#"{"a":1}"#)])
        let first = try await worker.project(source, context: "topic", schemaID: schema)
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.project(page([.text(#"{"b":2}"#)]), context: "topic", schemaID: schema)
        }
        do { _ = try await pending.value; Issue.record("Cancelled projection succeeded") }
        catch is CancellationError { }
        let retained = try await worker.project(source, context: "topic", schemaID: schema)
        #expect(retained.revision == first.revision)
    }

    @MainActor @Test("Expanded timestamp fields reuse the existing date display without changing their raw cell")
    func expandedTimestamp() async throws {
        let result = try await WorkspaceKafkaJSONTableWorker().project(page([.text(#"{"created_at":1720000000123}"#)]),
            context: "topic", schemaID: UUID())
        let column = try #require(result.columns.first { $0.name == "value.created_at" })
        let formatter = WorkspaceTimestampDisplayFormatter(timeZone: TimeZone(secondsFromGMT: 0))
        #expect(formatter.timestamp("1720000000123", column: column) == "2024-07-03 09:46:40")
        #expect(try cell(result, column.name) == .text("1720000000123"))
    }

    @MainActor @Test("Live JSON updates keep native columns and the user's resized widths")
    func nativeGridStability() async throws {
        let worker = WorkspaceKafkaJSONTableWorker(), schema = UUID(), stream = UUID()
        let first = try await worker.project(page([.text(#"{"a":1}"#)], live: .init(id: stream, firstSequence: 0, scrollRequest: 0)),
            context: "topic", schemaID: schema)
        let next = try await worker.project(page([.text(#"{"a":2,"b":3}"#)], firstID: 1,
            live: .init(id: stream, firstSequence: 1, scrollRequest: 0)), context: "topic", schemaID: schema)
        let scope = "kafka-json-test-\(UUID())"
        let coordinator = WorkspaceDatabaseDataTableCoordinator(page: first, isFetching: false, exportFileName: scope, sortData: { _ in })
        let scroll = coordinator.makeScrollView()
        let table = try #require(scroll.documentView as? NSTableView)
        let field = try #require(table.tableColumns.first { $0.title == "value.a" })
        field.width = 321
        let nativeColumns = table.tableColumns
        coordinator.update(page: next, isFetching: false, exportFileName: scope, sortData: { _ in })
        #expect(field.width == 321)
        #expect(table.tableColumns.count == nativeColumns.count)
        #expect(zip(table.tableColumns, nativeColumns).allSatisfy { $0 === $1 })
        #expect(table.numberOfRows == 1)
    }
}
