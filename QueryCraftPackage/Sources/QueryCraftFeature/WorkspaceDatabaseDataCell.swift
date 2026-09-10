public enum WorkspaceDatabaseDataCell: Codable, Equatable, Sendable {
    case null
    case text(String)
    case binary(byteCount: Int, preview: [UInt8] = [])

    var gridDisplayText: String {
        gridDisplayText(nullDisplayText: "NULL")
    }

    func gridDisplayText(
        nullDisplayText: String,
        emptyStringDisplayText: String = ""
    ) -> String {
        switch self {
        case .null:
            nullDisplayText
        case let .text(value):
            value.isEmpty ? emptyStringDisplayText : value
        case let .binary(byteCount, _):
            "<BINARY \(byteCount) bytes>"
        }
    }

    func gridPreviewText(
        nullDisplayText: String,
        emptyStringDisplayText: String = "",
        maximumCharacterCount: Int
    ) -> String {
        switch self {
        case .null:
            return nullDisplayText
        case let .text(value):
            guard !value.isEmpty else { return emptyStringDisplayText }
            return Self.boundedPreview(
                value,
                maximumCharacterCount: maximumCharacterCount
            )
        case let .binary(byteCount, _):
            return "<BINARY \(byteCount) bytes>"
        }
    }

    static func boundedPreview(
        _ value: String,
        maximumCharacterCount: Int,
        truncationIndicator: String = "..."
    ) -> String {
        let limit = max(0, maximumCharacterCount)
        guard limit > 0 else {
            return value.isEmpty ? "" : truncationIndicator
        }
        guard let boundary = value.index(
            value.startIndex,
            offsetBy: limit,
            limitedBy: value.endIndex
        ) else {
            return value
        }
        guard boundary != value.endIndex else { return value }
        return String(value[..<boundary]) + truncationIndicator
    }

    func textExceeds(characterCount: Int) -> Bool {
        guard case let .text(value) = self else { return false }
        let limit = max(0, characterCount)
        guard let boundary = value.index(
            value.startIndex,
            offsetBy: limit,
            limitedBy: value.endIndex
        ) else {
            return false
        }
        return boundary != value.endIndex
    }
}
