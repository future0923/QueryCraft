import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceDatabaseInspectorFieldTests {
    @Test @MainActor
    func selectedRowsReceiveColumnCommentsFromTableMetadata() throws {
        let column = WorkspaceDatabaseColumn(
            name: "user_nick", type: "varchar(20)", collation: nil,
            isNullable: true, key: "PRI", defaultValue: nil, extra: "",
            comment: "昵称（员工名称）"
        )
        let context = WorkspaceDatabaseInspectorContext(
            selection: .init(databaseName: "test", objectName: "users", kind: .table),
            detailsState: .loaded(.init(columns: [column], ddl: "")),
            page: .init(columns: [.init(id: 0, name: "user_nick")],
                        rows: [.init(id: 0, values: [.text("Alice")])],
                        offset: 0, limit: 200, hasNextPage: false),
            selectedRowIndexes: IndexSet(integer: 0), rowInsertEditor: .init(),
            pendingLoadedUpdates: [], schemaInspector: nil, isUpdatingLoadedValue: false,
            loadDetails: {}, updateLoadedValue: { _, _, _ in }, updateDraftValue: { _, _, _ in }
        )
        let field = try #require(context.fields?.first)
        #expect(field.comment == "昵称（员工名称）")
        #expect(field.type == "varchar(20)")
        #expect(field.editableText == "Alice")
        #expect(field.isEditable)
    }

    @Test
    func databaseTypeLabelPreservesAuthoritativeMySQLType() {
        let field = makeField(type: "  bigint unsigned  ")

        #expect(field.databaseTypeLabel == "bigint unsigned")
    }

    @Test
    func largeTextUsesBoundedDisplayPreview() {
        let fullValue = String(repeating: "x", count: 1_000_000)
        let field = makeField(type: "json", value: fullValue)

        #expect(field.isTextPreviewTruncated)
        #expect(
            field.editableText.count
                == WorkspaceDatabaseInspectorField
                    .maximumDisplayedTextCharacters + 3
        )
    }

    private func makeField(
        type: String,
        value: String = "value"
    ) -> WorkspaceDatabaseInspectorField {
        WorkspaceDatabaseInspectorField(
            id: "payload",
            name: "payload",
            type: type,
            value: .text(value),
            originalValue: .text(value),
            hasMultipleValues: false,
            isModified: false,
            source: .loaded(
                rowIndexes: IndexSet(integer: 0),
                dataColumnIndex: 0
            ),
            isEditable: true,
            editDisabledReason: nil,
            isNullable: true,
            canUseDefault: false,
            isPrimaryKey: false
        )
    }
}
