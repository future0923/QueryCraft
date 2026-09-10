enum RedisKeySearchMatchMode: String, CaseIterable, Equatable, Identifiable,
    Sendable
{
    case contains
    case prefix
    case exact

    var id: String { rawValue }

    @MainActor
    var title: String {
        title(using: .current)
    }

    func title(using copy: AppCopy) -> String {
        switch self {
        case .contains:
            copy.text("包含", "Contains")
        case .prefix:
            copy.text("前缀", "Prefix")
        case .exact:
            copy.text("精确", "Exact")
        }
    }

    func scanPattern(for searchText: String) -> String? {
        guard !searchText.isEmpty else { return nil }
        switch self {
        case .contains:
            return searchText.contains("*")
                ? searchText
                : "*\(searchText)*"
        case .prefix:
            let literal = Self.escapedGlobLiteral(searchText)
            return "\(literal)*"
        case .exact:
            return Self.escapedGlobLiteral(searchText)
        }
    }

    private static func escapedGlobLiteral(_ source: String) -> String {
        var result = ""
        for character in source {
            if character == "\\"
                || character == "*"
                || character == "?"
                || character == "["
                || character == "]"
            {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
