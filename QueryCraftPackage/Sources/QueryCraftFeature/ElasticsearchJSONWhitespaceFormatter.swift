import Foundation

/// Changes whitespace only. Numbers, key order and string escapes remain byte exact.
enum ElasticsearchJSONWhitespaceFormatter {
    static func format(_ data: Data, compact: Bool = false) throws -> String {
        _ = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        var output = [UInt8]()
        output.reserveCapacity(data.count)
        var depth = 0
        var quoted = false
        var escaped = false
        var previous: UInt8?
        for (offset, byte) in data.enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            if quoted {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            if [9, 10, 13, 32].contains(byte) { continue }
            if !compact, let previous, previous == 123 || previous == 91,
               byte != 125 && byte != 93 {
                output.append(10)
                output.append(contentsOf: repeatElement(32, count: depth * 2))
            }
            switch byte {
            case 34: quoted = true; output.append(byte)
            case 123, 91: depth += 1; output.append(byte)
            case 125, 93:
                depth = max(0, depth - 1)
                if !compact, previous != 123 && previous != 91 {
                    output.append(10)
                    output.append(contentsOf: repeatElement(32, count: depth * 2))
                }
                output.append(byte)
            case 44:
                output.append(byte)
                if !compact {
                    output.append(10)
                    output.append(contentsOf: repeatElement(32, count: depth * 2))
                }
            case 58:
                if !compact { output.append(32) }
                output.append(byte)
                if !compact { output.append(32) }
            default: output.append(byte)
            }
            previous = byte
        }
        return String(decoding: output, as: UTF8.self)
    }
}
