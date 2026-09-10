extension RedisReplyValue {
    var formattedText: String {
        formattedText(indentation: 0)
    }

    private func formattedText(indentation: Int) -> String {
        let prefix = String(repeating: "  ", count: indentation)
        return switch self {
        case let .simpleString(value), let .bulkString(value):
            value
        case let .integer(value):
            String(value)
        case let .double(value):
            value.formatted()
        case let .boolean(value):
            value ? "true" : "false"
        case let .array(values), let .set(values):
            values.enumerated().map { index, value in
                "\(prefix)\(index + 1)) \(value.formattedText(indentation: indentation + 1))"
            }.joined(separator: "\n")
        case let .map(entries):
            entries.map { entry in
                "\(prefix)\(entry.key.formattedText(indentation: indentation + 1)): \(entry.value.formattedText(indentation: indentation + 1))"
            }.joined(separator: "\n")
        case .null:
            "(nil)"
        case let .error(message):
            "(error) \(message)"
        }
    }
}
