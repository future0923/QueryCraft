import AppKit
import Foundation
import Testing

@testable import QueryCraftFeature

struct WorkspaceQueryResultInspectorTests {
    @Test
    func selectedRowMapsEveryColumnWithoutCollapsingValueKinds() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let page = WorkspaceQueryResultPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "missing", type: "varchar"),
                WorkspaceDatabaseDataColumn(id: 1, name: "blank", type: "varchar"),
                WorkspaceDatabaseDataColumn(id: 2, name: "payload", type: "json"),
                WorkspaceDatabaseDataColumn(id: 3, name: "bytes", type: "blob"),
            ],
            store: store,
            rowCount: 1
        )
        let row = WorkspaceDatabaseDataRow(
            id: 0,
            values: [
                .null,
                .text(""),
                .text(#"{"ready":true}"#),
                .binary(byteCount: 8, preview: [0, 15, 16, 255]),
            ]
        )

        let context = WorkspaceQueryResultInspectorContext(
            page: page,
            selectedRowIndex: 0,
            row: row
        )
        let fields = try #require(context.fields)

        #expect(fields.map(\.name) == ["missing", "blank", "payload", "bytes"])
        #expect(fields.map(\.type) == ["varchar", "varchar", "json", "blob"])
        #expect(fields[0].value == .null)
        #expect(fields[1].value == .text(""))
        #expect(fields[2].shouldFormatJSON)
        #expect(fields[3].copyText == "00 0F 10 FF")
        #expect(fields[3].binaryDisplay?.byteCount == 8)
        #expect(fields[3].binaryDisplay?.previewCount == 4)
    }

    @Test
    func noSelectedRowDoesNotExposeFields() throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        let context = WorkspaceQueryResultInspectorContext(
            page: WorkspaceQueryResultPage(
                columns: [
                    WorkspaceDatabaseDataColumn(id: 0, name: "value")
                ],
                store: store,
                rowCount: 1
            )
        )

        #expect(context.fields == nil)
        #expect(context.selectedRowIndex == nil)
        #expect(!context.isLoading)
    }

    @Test
    func searchPreviewIsBoundedForLongText() {
        let field = WorkspaceQueryResultInspectorField(
            id: "long",
            name: "body",
            type: "longtext",
            value: .text(String(repeating: "x", count: 10_000))
        )

        #expect(field.searchPreview.count == 4_096)
        #expect(field.isLongText)
    }

    @Test
    func largeTextUsesBoundedInspectorPreviewButCopiesTheFullValue() {
        let fullValue = String(repeating: "x", count: 1_000_000)
        let field = WorkspaceQueryResultInspectorField(
            id: "large",
            name: "payload",
            type: "json",
            value: .text(fullValue)
        )

        #expect(field.isTextPreviewTruncated)
        #expect(
            field.displayedText?.count
                == WorkspaceQueryResultInspectorField
                    .maximumDisplayedTextCharacters + 3
        )
        #expect(!field.shouldFormatJSON)
        #expect(field.copyText == fullValue)
    }

    @Test
    func JSONFormattingIsPrettyAndPreservesKeyOrder() async throws {
        let formatted = try #require(
            try await WorkspaceQueryResultInspectorFormatter.shared
                .formattedJSON(#"{"z":2,"a":1}"#)
        )
        let firstKey = try #require(formatted.range(of: "\"z\""))
        let secondKey = try #require(formatted.range(of: "\"a\""))

        #expect(formatted.contains("\n"))
        #expect(firstKey.lowerBound < secondKey.lowerBound)
    }

    @Test
    func invalidJSONIsRejected() async {
        await #expect(throws: (any Error).self) {
            try await WorkspaceQueryResultInspectorFormatter.shared
                .formattedJSON("{invalid}")
        }
    }

    @Test @MainActor
    func directDrawSelectionPublishesExactlyOneResultRow() async throws {
        let store = try WorkspaceQueryResultStore(temporary: false)
        try await store.append([
            WorkspaceDatabaseDataRow(id: 0, values: [.text("first")]),
            WorkspaceDatabaseDataRow(id: 1, values: [.text("second")]),
        ])
        let page = WorkspaceQueryResultPage(
            columns: [
                WorkspaceDatabaseDataColumn(id: 0, name: "value", type: "varchar")
            ],
            store: store,
            rowCount: 2
        )
        var publishedContext: WorkspaceQueryResultInspectorContext?
        let coordinator = WorkspaceQueryResultTableCoordinator(
            page: page,
            updateInspectorContext: { publishedContext = $0 }
        )
        let scrollView = coordinator.makeScrollView()
        let tableView = try #require(
            scrollView.documentView as? WorkspaceDirectDrawTableView
        )

        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 1, column: 1),
            active: WorkspaceGridCoordinate(row: 1, column: 1)
        )
        await Task.yield()
        await Task.yield()

        #expect(publishedContext?.selectedRowIndex == 1)
        #expect(publishedContext?.row?.values == [.text("second")])

        try await store.append([
            WorkspaceDatabaseDataRow(id: 2, values: [.text("third")])
        ])
        coordinator.update(
            page: WorkspaceQueryResultPage(
                columns: page.columns,
                store: store,
                rowCount: 3
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(tableView.selectedDataRowIndexesForActions == IndexSet(integer: 1))
        #expect(publishedContext?.selectedRowIndex == 1)

        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 0, column: 1),
            active: WorkspaceGridCoordinate(row: 1, column: 1)
        )
        await Task.yield()
        await Task.yield()

        #expect(publishedContext?.selectedRowIndex == nil)
        #expect(publishedContext?.fields == nil)
    }
}
