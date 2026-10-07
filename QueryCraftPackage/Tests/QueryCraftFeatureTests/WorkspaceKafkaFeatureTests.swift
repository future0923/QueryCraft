import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceKafkaFeatureTests {
    @Test("Scan matching preserves whitespace and distinguishes null, fields, case, and exact values")
    func scanMatching() {
        let value = WorkspaceKafkaScanRequest(text: "订单AbC")
        #expect(value.matches(key: nil, value: "{订单abc: 1}"))
        #expect(!value.matches(key: "订单abc", value: nil))
        #expect(!WorkspaceKafkaScanRequest(text: "NULL").matches(key: nil, value: nil))
        #expect(WorkspaceKafkaScanRequest(field: .keyOrValue, text: "abc").matches(key: "ABC", value: nil))
        #expect(!WorkspaceKafkaScanRequest(text: "abc", caseSensitive: true).matches(key: nil, value: "ABC"))
        #expect(!WorkspaceKafkaScanRequest(match: .exact, text: "abc").matches(key: nil, value: " abc "))
        #expect(WorkspaceKafkaScanRequest(match: .exact, text: " abc ").matches(key: nil, value: " ABC "))
        #expect(WorkspaceKafkaScanRequest(field: .key, text: "base64:/w==").matches(key: "base64:/w==", value: nil))
    }

    @Test("Scan limits reject empty patterns and unbounded requests")
    func scanValidation() {
        #expect(!WorkspaceKafkaScanRequest(text: "").isValid)
        #expect(!WorkspaceKafkaScanRequest(text: "x", maximumMessages: 0).isValid)
        #expect(!WorkspaceKafkaScanRequest(text: "x", maximumMessages: 100_001).isValid)
        #expect(WorkspaceKafkaScanRequest(text: " ", maximumMessages: 100_000).isValid)
    }

    @Test("Opening a Kafka topic creates a data-only object tab")
    func topicSelectionOpensDataObject() {
        let tabs = WorkspaceContentTabsModel()
        let topic = WorkspaceDatabaseObjectSelection(
            databaseName: "Kafka",
            objectName: "orders.events",
            kind: .table
        )

        tabs.open(topic)

        #expect(tabs.selectedContentID == .databaseObject(topic))
        #expect(tabs.contentItems.map(\.id) == [.databaseObject(topic)])
    }

    @Test("A single selected Kafka row is available to the raw value inspector")
    func inspectorContextMapsSelectedMessage() throws {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "partition", type: "INT"),
            WorkspaceDatabaseDataColumn(id: 1, name: "offset", type: "BIGINT"),
            WorkspaceDatabaseDataColumn(id: 2, name: "timestamp", type: "BIGINT"),
            WorkspaceDatabaseDataColumn(id: 3, name: "key", type: "TEXT"),
            WorkspaceDatabaseDataColumn(id: 4, name: "headers", type: "TEXT"),
            WorkspaceDatabaseDataColumn(id: 5, name: "value", type: "TEXT"),
        ]
        let row = WorkspaceDatabaseDataRow(
            id: 42,
            values: [
                .text("2"),
                .text("42"),
                .text("1700000000000"),
                .text("order-42"),
                .text("trace=abc"),
                .text("{\"orderId\":42}"),
            ]
        )
        let page = WorkspaceDatabaseDataPage(
            columns: columns,
            rows: [row],
            offset: 0,
            limit: 50,
            hasNextPage: false
        )

        let context = WorkspaceKafkaMessageInspectorContext(
            topic: "orders.events",
            page: page,
            selectedRowIndexes: IndexSet(integer: 0)
        )

        let selected = try #require(context.row)
        #expect(selected.value(at: 5) == .text("{\"orderId\":42}"))
        #expect(context.columns.map(\.name) == columns.map(\.name))
        #expect(context.searchIdentity == "kafka-message:orders.events:2:42")
    }

    @Test("Kafka message identity uses partition and offset instead of page row id")
    func inspectorIdentityTracksKafkaPosition() {
        let columns = [
            WorkspaceDatabaseDataColumn(id: 0, name: "partition"),
            WorkspaceDatabaseDataColumn(id: 1, name: "offset"),
            WorkspaceDatabaseDataColumn(id: 2, name: "value"),
        ]
        let firstPage = WorkspaceDatabaseDataPage(
            columns: columns,
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("0"), .text("10"), .text("first")]
                ),
            ],
            offset: 0,
            limit: 50,
            hasNextPage: true
        )
        let secondPage = WorkspaceDatabaseDataPage(
            columns: columns,
            rows: [
                WorkspaceDatabaseDataRow(
                    id: 0,
                    values: [.text("1"), .text("10"), .text("second")]
                ),
            ],
            offset: 0,
            limit: 50,
            hasNextPage: true
        )

        let first = WorkspaceKafkaMessageInspectorContext(
            topic: "events",
            page: firstPage,
            selectedRowIndexes: IndexSet(integer: 0)
        )
        let second = WorkspaceKafkaMessageInspectorContext(
            topic: "events",
            page: secondPage,
            selectedRowIndexes: IndexSet(integer: 0)
        )

        #expect(first.searchIdentity != second.searchIdentity)
        #expect(first.searchIdentity == "kafka-message:events:0:10")
        #expect(second.searchIdentity == "kafka-message:events:1:10")
    }

    @Test("Kafka message inspector has no row for an empty or multi-selection")
    func inspectorContextRequiresSingleRow() {
        let page = WorkspaceDatabaseDataPage(
            columns: [WorkspaceDatabaseDataColumn(id: 0, name: "value")],
            rows: [
                WorkspaceDatabaseDataRow(id: 0, values: [.text("one")]),
                WorkspaceDatabaseDataRow(id: 1, values: [.text("two")]),
            ],
            offset: 0,
            limit: 50,
            hasNextPage: false
        )

        let empty = WorkspaceKafkaMessageInspectorContext(
            topic: "events",
            page: page,
            selectedRowIndexes: []
        )
        let multiple = WorkspaceKafkaMessageInspectorContext(
            topic: "events",
            page: page,
            selectedRowIndexes: IndexSet(integersIn: 0..<2)
        )

        #expect(empty.row == nil)
        #expect(multiple.row == nil)
    }

    @Test("Kafka sessions are read-only")
    func kafkaCapabilitiesDisableMutationsAndTransactions() {
        #expect(WorkspaceSessionCapabilities.kafka.supportsDataEditing == false)
        #expect(WorkspaceSessionCapabilities.kafka.supportsTransactions == false)
        #expect(
            WorkspaceSessionCapabilities.kafka.readOnlyExecution
                == .classifiedStatementsOnly
        )
    }
}
