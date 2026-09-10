import Foundation

struct WorkspaceElasticsearchConsoleDiagnostic: Equatable, Sendable {
    let message: String
    let line: Int?
    let column: Int?
    let documentRange: NSRange?

    static func extract(_ errors: [Any], parsed: ElasticsearchConsoleParsedRequest?,
                        source: String?) throws -> [Self] {
        var pending = Array(errors.reversed())
        var result: [Self] = []
        var inspected = 0
        while let value = pending.popLast(), inspected < 128, result.count < 16 {
            try Task.checkCancellation()
            inspected += 1
            if let message = value as? String {
                let item = Self(message: message, line: nil, column: nil, documentRange: nil)
                if !result.contains(item) { result.append(item) }
                continue
            }
            guard let object = value as? [String: Any] else { continue }
            let type = object["type"] as? String
            let reason = object["reason"] as? String
            if type != nil || reason != nil {
                let message = [type, reason].compactMap { $0 }.joined(separator: ": ")
                let line = object["line"] as? Int
                let column = object["col"] as? Int ?? object["column"] as? Int
                let location = line.flatMap { line in column.map { (line, $0) } }
                    ?? locationInReason(reason)
                let range = location.flatMap { line, column in
                    guard let parsed, let source,
                          ["parsing_exception", "x_content_parse_exception", "named_object_not_found_exception"]
                            .contains(type ?? "") else { return nil as NSRange? }
                    return bodyLocation(line: line, column: column, parsed: parsed, source: source)
                }
                let item = Self(message: message, line: location?.0, column: location?.1, documentRange: range)
                if !result.contains(item) { result.append(item) }
            }
            if let causedBy = object["caused_by"] { pending.append(causedBy) }
            if let reason = object["reason"] as? [String: Any] { pending.append(reason) }
            if let error = object["error"] { pending.append(error) }
            pending.append(contentsOf: (object["root_cause"] as? [Any] ?? []).prefix(16).reversed())
        }
        return result
    }

    private static func locationInReason(_ reason: String?) -> (Int, Int)? {
        guard let reason, let regex = try? NSRegularExpression(pattern: #"^\[(\d+):(\d+)\]"#),
              let match = regex.firstMatch(in: reason, range: NSRange(location: 0, length: (reason as NSString).length)),
              let line = Int((reason as NSString).substring(with: match.range(at: 1))),
              let column = Int((reason as NSString).substring(with: match.range(at: 2))) else { return nil }
        return (line, column)
    }

    /// ES parses the transmitted UTF-8 body. Its 1-based byte column must be
    /// converted to an AppKit UTF-16 range, including the request's body offset.
    static func bodyLocation(line: Int, column: Int, parsed: ElasticsearchConsoleParsedRequest,
                             source: String) -> NSRange? {
        guard line > 0, column > 0, let body = parsed.request.body else { return nil }
        let bytes = Array(body)
        var currentLine = 1, lineStart = 0
        for (offset, byte) in bytes.enumerated() {
            if offset.isMultiple(of: 4096), Task.isCancelled { return nil }
            if currentLine == line { break }
            if byte == 10 { currentLine += 1; lineStart = offset + 1 }
        }
        guard currentLine == line, column - 1 <= bytes.count - lineStart else { return nil }
        let offset = lineStart + column - 1
        guard !bytes[lineStart..<offset].contains(10),
              let prefix = String(bytes: bytes[..<offset], encoding: .utf8) else { return nil }
        let location = parsed.bodyRange.location + (prefix as NSString).length
        let text = source as NSString
        guard location <= NSMaxRange(parsed.bodyRange), location <= text.length else { return nil }
        let length = location < min(NSMaxRange(parsed.bodyRange), text.length)
            ? text.rangeOfComposedCharacterSequence(at: location).length : 0
        return NSRange(location: location, length: length)
    }
}
