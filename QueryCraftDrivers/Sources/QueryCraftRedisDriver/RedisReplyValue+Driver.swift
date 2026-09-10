import QueryCraftFeature

extension RedisReplyValue {
    var stringValue: String? {
        switch self {
        case .simpleString(let value), .bulkString(let value):
            value
        case .integer(let value):
            String(value)
        case .double(let value):
            Self.displayString(for: value)
        case .boolean(let value):
            value ? "1" : "0"
        case .array, .map, .set, .null, .error:
            nil
        }
    }

    private static func displayString(for value: Double) -> String {
        if value == 0 { return "0" }
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    var integerValue: Int64? {
        switch self {
        case .integer(let value):
            value
        case .simpleString(let value), .bulkString(let value):
            Int64(value)
        case .double, .boolean, .array, .map, .set, .null, .error:
            nil
        }
    }

    var collectionValues: [RedisReplyValue]? {
        switch self {
        case .array(let values), .set(let values):
            values
        case .simpleString, .bulkString, .integer, .double, .boolean,
             .map, .null, .error:
            nil
        }
    }
}
