import Foundation

struct MobileTextSegment {
    let start: String.Index
    let end: String.Index
    let offset: Int
    static func range(in source: String, offset proposed: Int, maximumBytes: Int = 32_768) -> Self {
        let bytes = source.utf8
        var offset = min(max(0, proposed), bytes.count)
        var start = bytes.index(bytes.startIndex, offsetBy: offset)
        while start != bytes.startIndex && start != bytes.endIndex && bytes[start] & 0xC0 == 0x80 { start = bytes.index(before: start); offset -= 1 }
        var end = bytes.index(start, offsetBy: min(maximumBytes, bytes.distance(from: start, to: bytes.endIndex)))
        while end != bytes.endIndex && bytes[end] & 0xC0 == 0x80 { end = bytes.index(after: end) }
        return .init(start: start, end: end, offset: offset)
    }
    func text(in source: String) -> String { String(decoding: source.utf8[start..<end], as: UTF8.self) }
    func replacing(in source: String, with value: String) -> String {
        String(decoding: source.utf8[..<start], as: UTF8.self) + value + String(decoding: source.utf8[end...], as: UTF8.self)
    }
}
