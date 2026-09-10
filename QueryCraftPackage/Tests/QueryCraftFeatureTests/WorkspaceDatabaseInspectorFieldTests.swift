import Foundation
import Testing
@testable import QueryCraftFeature

struct WorkspaceDatabaseInspectorFieldTests {
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
