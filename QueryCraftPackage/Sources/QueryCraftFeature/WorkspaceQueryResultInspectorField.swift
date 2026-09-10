struct WorkspaceQueryResultInspectorField: Equatable, Identifiable, Sendable {
    static let maximumDisplayedTextCharacters = 4_096
    static let maximumSearchPreviewCharacters = 4_096

    let id: String
    let name: String
    let type: String
    let value: WorkspaceDatabaseDataCell

    var searchPreview: String {
        switch value {
        case .null:
            "NULL"
        case .text(let text):
            WorkspaceDatabaseDataCell.boundedPreview(
                text,
                maximumCharacterCount: Self.maximumSearchPreviewCharacters,
                truncationIndicator: ""
            )
        case .binary(let byteCount, _):
            "BINARY \(byteCount)"
        }
    }

    var textValue: String? {
        guard case .text(let text) = value else { return nil }
        return text
    }

    var shouldFormatJSON: Bool {
        guard let textValue else { return false }
        guard !isTextPreviewTruncated else { return false }
        if type.localizedCaseInsensitiveContains("json") {
            return true
        }
        guard let first = textValue.first(where: { !$0.isWhitespace }) else {
            return false
        }
        return first == "{" || first == "["
    }

    var isLongText: Bool {
        guard let textValue else { return false }
        if isTextPreviewTruncated { return true }
        let preview = textValue.prefix(121)
        return preview.count > 120 || preview.contains("\n")
    }

    var displayedText: String? {
        guard case .text = value else { return nil }
        return value.gridPreviewText(
            nullDisplayText: "NULL",
            maximumCharacterCount: Self.maximumDisplayedTextCharacters
        )
    }

    var isTextPreviewTruncated: Bool {
        value.textExceeds(
            characterCount: Self.maximumDisplayedTextCharacters
        )
    }

    var copyText: String {
        switch value {
        case .null:
            "NULL"
        case .text(let text):
            text
        case .binary(_, let preview):
            Self.hexText(preview)
        }
    }

    var binaryDisplay: (byteCount: Int, previewCount: Int, hex: String)? {
        guard case .binary(let byteCount, let preview) = value else { return nil }
        return (byteCount, preview.count, Self.hexText(preview))
    }

    private static func hexText(_ bytes: [UInt8]) -> String {
        bytes.map { byte in
            let value = String(byte, radix: 16, uppercase: true)
            return value.count == 1 ? "0\(value)" : value
        }.joined(separator: " ")
    }
}
