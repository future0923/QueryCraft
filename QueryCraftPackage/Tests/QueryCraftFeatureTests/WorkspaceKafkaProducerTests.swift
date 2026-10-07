import Foundation
import AppKit
import Testing
@testable import QueryCraftFeature

@MainActor @Suite("Kafka message composer", .timeLimit(.minutes(1)))
struct WorkspaceKafkaProducerTests {
    @Test("Copy preserves raw bytes, duplicate headers, nulls and empty values", arguments: [
        Data(#""{\"taskId\":2104625183447121922}""#.utf8),
        Data("{ \"id\": 18446744073709551615 }\n".utf8),
        Data("base64:literal, x=y\nplain text".utf8), Data([0xff, 0, 0x80]), Data(), nil
    ] as [Data?])
    func copyPayload(_ value: Data?) async throws {
        let source = WorkspaceKafkaMessageReference(topic: "events", partition: 2, offset: 999)
        let headers: [WorkspaceKafkaProducerHeader] = [
            .init(name: "trace", value: Data("a, b=c\n".utf8)),
            .init(name: "trace", value: nil), .init(name: "trace", value: Data()),
            .init(name: "bytes", value: Data([0xff, 0]))
        ]
        let editor = WorkspaceKafkaProducerModel(topic: source.topic, source: source)
        #expect(throws: WorkspaceKafkaMessageCopyError.self) { try editor.request() }
        await editor.loadSource {
            #expect($0 == source)
            return .init(key: value, value: value, headers: headers)
        }
        let request = try editor.request()
        #expect(request.topic == "events" && request.partition == 2)
        #expect(request.key == value && request.value == (value ?? Data()))
        #expect(request.isNullValue == (value == nil))
        #expect(request.headers == headers)
        #expect(editor.receipt == nil && editor.isSending == false)
        if editor.format == .base64 {
            editor.value = "not base64!"
            #expect(throws: WorkspaceKafkaMessageCopyError.self) { try editor.request() }
        }
    }

    @Test("Failed copy is not sendable, retry loads once and preserves edits")
    func retryCopy() async throws {
        let editor = WorkspaceKafkaProducerModel(topic: "events", source: .init(topic: "events", partition: 0, offset: 42))
        await editor.loadSource { _ in throw WorkspaceKafkaMessageCopyError.unavailable }
        #expect(editor.needsSource && editor.error != nil)
        await editor.send { _ in Issue.record("Failed copy must never send an empty message"); return .init(partition: 0, offset: 0) }
        await editor.loadSource { _ in .init(key: nil, value: Data("hello".utf8), headers: []) }
        editor.value = "edited"
        await editor.loadSource { _ in Issue.record("A loaded draft must not be overwritten"); return .init(key: nil, value: nil, headers: []) }
        #expect(try editor.request().value == Data("edited".utf8))
    }

    @Test("Context menu snapshots raw partition and offset instead of row number or formatted timestamp")
    func copyMenu() throws {
        var copied: WorkspaceKafkaMessageReference?
        let action = WorkspaceKafkaMessageCopyAction(topic: "events", open: { copied = $0 })
        let columns: [WorkspaceDatabaseDataColumn] = [.init(id: 0, name: "offset", type: "BIGINT"), .init(id: 1, name: "partition", type: "INT")]
        let item = try #require(action.menuItem(row: .init(id: 900, values: [.text("9223372036854775806"), .text("2")]), columns: columns))
        let selector = try #require(item.action)
        #expect(NSApplication.shared.sendAction(selector, to: item.target, from: item))
        #expect(copied == .init(topic: "events", partition: 2, offset: 9223372036854775806))
        #expect(action.menuItem(row: .init(id: 0, values: [.null, .text("2")]), columns: columns) == nil)
    }

    @Test("Removing an editing Header uses stable identity and stale bindings cannot edit its neighbors")
    func removeEditingHeader() throws {
        let editor = WorkspaceKafkaProducerModel(topic: "events")
        editor.headers = [.init(name: "trace", value: "first"), .init(name: "trace", value: "middle"),
                          .init(name: "trace", value: "last")]
        let rows = editor.headers.map { WorkspaceKafkaProducerHeaderRow(header: $0, editor: editor) }
        let middleName = rows[1].binding(for: \.name)
        let middleValue = rows[1].binding(for: \.value)
        let lastValue = rows[2].binding(for: \.value)
        middleName.wrappedValue = "edited"
        rows[1].remove()
        #expect(editor.headers.map(\.id) == [rows[0].header.id, rows[2].header.id])
        // Simulate a late TextField read/write while SwiftUI removes the row.
        #expect(middleValue.wrappedValue == "middle")
        middleValue.wrappedValue = "late commit"
        rows[1].remove()
        #expect(editor.headers.map(\.value) == ["first", "last"])
        lastValue.wrappedValue = "still editable"
        #expect(editor.headers.last?.value == "still editable")
        rows[0].remove()
        rows[2].remove()
        #expect(editor.headers.isEmpty)
        editor.headers.append(.init(name: "new", value: "new value"))
        lastValue.wrappedValue = "stale write"
        #expect(try editor.request().headers == [.init(name: "new", value: Data("new value".utf8))])
    }

    @Test("JSON is validated without changing payload; text, null keys and duplicate headers are preserved")
    func draftValidation() throws {
        let editor = WorkspaceKafkaProducerModel(topic: "events")
        editor.value = "{ \"中文\": 42 }"
        editor.partition = " 2 "
        editor.headers = [.init(name: "trace", value: "a"), .init(name: "trace", value: "b")]
        let request = try editor.request()
        #expect(request.value == Data(editor.value.utf8) && request.key == nil && request.partition == 2)
        #expect(request.headers.map(\.name) == ["trace", "trace"])
        editor.usesNullKey = false
        #expect(try editor.request().key == Data())
        editor.value = "invalid JSON"
        #expect(editor.validationMessage != nil)
        editor.isJSON = false
        #expect(try editor.request().value == Data("invalid JSON".utf8))
        editor.partition = "-1"
        #expect(throws: WorkspaceKafkaProduceError.self) { try editor.request() }
        editor.partition = "2147483648"
        #expect(throws: WorkspaceKafkaProduceError.self) { try editor.request() }
        editor.partition = ""
        editor.headers = [.init(name: "", value: "")]
        #expect(throws: WorkspaceKafkaProduceError.self) { try editor.request() }
    }

    @Test("Size checks include UTF-8 key and header bytes; unsafe topics are rejected")
    func wireValidation() {
        for topic in ["", ".", "..", "events\0other", "a/b"] {
            #expect(throws: WorkspaceKafkaProduceError.self) {
                try WorkspaceKafkaProduceRequest(topic: topic, value: Data()).validate()
            }
        }
        #expect(throws: WorkspaceKafkaProduceError.self) {
            try WorkspaceKafkaProduceRequest(topic: "events", key: Data("中".utf8),
                value: Data(repeating: 0, count: WorkspaceKafkaProduceRequest.maximumBytes - 2)).validate()
        }
        #expect(throws: WorkspaceKafkaProduceError.self) {
            try WorkspaceKafkaProduceRequest(topic: "events", value: Data(),
                headers: [.init(name: "x\0y", value: nil)]).validate()
        }
    }

    @Test("Format preserves the JSON value and supports scalar JSON")
    func format() throws {
        let editor = WorkspaceKafkaProducerModel(topic: "events")
        editor.value = "{\"b\":2,\"a\":[true,null]}"
        editor.formatJSON()
        #expect(editor.value.contains("\n") && editor.validationMessage == nil)
        editor.value = "42"
        editor.formatJSON()
        #expect(editor.value == "42")
    }

    @Test("Concurrent Send clicks submit once; only broker completion supplies a receipt")
    func sendOnce() async throws {
        let editor = WorkspaceKafkaProducerModel(topic: "events")
        let gate = AsyncStream<Void>.makeStream()
        var calls = 0
        let task = Task {
            await editor.send { _ in
                calls += 1
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
                return .init(partition: 1, offset: 42)
            }
        }
        while !editor.isSending { await Task.yield() }
        #expect(editor.receipt == nil)
        await editor.send { _ in calls += 1; return .init(partition: 0, offset: 0) }
        #expect(calls == 1)
        gate.continuation.finish()
        await task.value
        #expect(editor.receipt == .init(partition: 1, offset: 42) && !editor.isSending)
        let original = editor.value
        await editor.send { _ in throw WorkspaceKafkaProduceError.deliveryUnconfirmed("timeout") }
        #expect(editor.receipt == nil && editor.error != nil && !editor.isSending)
        #expect(editor.value == original)
    }

    @Test("An invalid JSON draft never calls the producer")
    func invalidDraftDoesNotSend() async {
        let editor = WorkspaceKafkaProducerModel(topic: "events")
        editor.value = "{"
        await editor.send { _ in
            Issue.record("Invalid JSON must not be dispatched")
            return .init(partition: 0, offset: 0)
        }
        #expect(editor.error != nil && !editor.isSending && editor.receipt == nil)
    }
}
