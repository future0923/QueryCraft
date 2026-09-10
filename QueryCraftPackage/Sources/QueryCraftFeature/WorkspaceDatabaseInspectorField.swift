import Foundation

struct WorkspaceDatabaseInspectorField: Equatable, Identifiable, Sendable {
    static let maximumDisplayedTextCharacters = 4_096
    static let maximumSearchPreviewCharacters = 4_096

    enum Source: Equatable, Sendable {
        case loaded(rowIndexes: IndexSet, dataColumnIndex: Int)
        case draft(rowIDs: [UUID], columnName: String)
    }

    enum Value: Equatable, Sendable {
        case required
        case useDefault
        case null
        case text(String)
        case binary(byteCount: Int)
    }

    let id: String
    let name: String
    let type: String
    let value: Value
    let originalValue: Value
    let hasMultipleValues: Bool
    let isModified: Bool
    let source: Source
    let isEditable: Bool
    let editDisabledReason: String?
    let isNullable: Bool
    let canUseDefault: Bool
    let isPrimaryKey: Bool

    var editableText: String {
        guard case let .text(value) = self.value else { return "" }
        return WorkspaceDatabaseDataCell.boundedPreview(
            value,
            maximumCharacterCount: Self.maximumDisplayedTextCharacters
        )
    }

    var isTextPreviewTruncated: Bool {
        guard case let .text(value) = self.value else { return false }
        return WorkspaceDatabaseDataCell.text(value).textExceeds(
            characterCount: Self.maximumDisplayedTextCharacters
        )
    }

    var databaseTypeLabel: String {
        type.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
