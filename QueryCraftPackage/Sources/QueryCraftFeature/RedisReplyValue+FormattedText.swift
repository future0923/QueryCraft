#if os(iOS)
import QueryCraftMobileCore
#endif
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


extension RedisReplyValue {
    // Bounded rendering for touch devices; the existing desktop formatter remains unchanged.
    func boundedText(maximumBytes: Int = 65_536) -> String {
        var output = "", remaining = max(0, maximumBytes), nodes = 0, truncated = false
        func append(_ text: String) {
            guard remaining > 0 else { truncated = true; return }
            let bytes = text.utf8.prefix(remaining)
            output += String(decoding: bytes, as: UTF8.self); remaining -= bytes.count
            if bytes.count < text.utf8.count { truncated = true }
        }
        func render(_ value: RedisReplyValue, depth: Int) {
            guard remaining > 0, depth < 32, nodes < 2_000 else { truncated = true; return }
            nodes += 1
            switch value {
            case .array(let values), .set(let values):
                for (index, item) in values.enumerated() {
                    guard remaining > 0, nodes < 2_000 else { truncated = true; break }
                    append("\(index + 1)) "); render(item, depth: depth + 1); append("\n")
                }
            case .map(let entries):
                for entry in entries {
                    guard remaining > 0, nodes < 2_000 else { truncated = true; break }
                    render(entry.key, depth: depth + 1); append(": "); render(entry.value, depth: depth + 1); append("\n")
                }
            default: append(value.formattedText)
            }
        }
        render(self, depth: 0)
        if truncated { output += "\n…输出已截断" }
        return output
    }
}

extension RedisReplyValue {
    func estimatedByteCount(upTo limit: Int) -> Int {
        var bytes = 0, nodes = 0
        func visit(_ value: RedisReplyValue, depth: Int) {
            guard bytes <= limit else { return }
            guard depth < 32, nodes < 2_000 else { bytes = limit + 1; return }
            nodes += 1; bytes += 16
            switch value {
            case .simpleString(let value), .bulkString(let value), .error(let value): bytes += value.utf8.count
            case .array(let values), .set(let values):
                for value in values { visit(value, depth: depth + 1); if bytes > limit { break } }
            case .map(let entries):
                for entry in entries { visit(entry.key, depth: depth + 1); visit(entry.value, depth: depth + 1); if bytes > limit { break } }
            default: break
            }
        }
        visit(self, depth: 0); return min(bytes, limit + 1)
    }
    func retainedTranscriptReply(maximumBytes: Int) -> RedisReplyValue {
        guard estimatedByteCount(upTo: maximumBytes) > maximumBytes else { return self }
        return .bulkString("[仅保留回复展示前缀]\n" + boundedText(maximumBytes: maximumBytes))
    }
}
