import Foundation

enum RedisHexCodec {
    static func format(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: data.count * 3 - 1) { buffer in
            var offset = 0
            for (index, byte) in data.enumerated() {
                if index > 0 { buffer[offset] = index.isMultiple(of: 16) ? 0x0A : 0x20; offset += 1 }
                buffer[offset] = digits[Int(byte >> 4)]; buffer[offset + 1] = digits[Int(byte & 15)]; offset += 2
            }
            return offset
        }
    }
    static func parse(_ source: String) -> Data? {
        var data = Data(); data.reserveCapacity(source.utf8.count / 2)
        var high: UInt8?
        for scalar in source.unicodeScalars {
            let code = scalar.value
            if code == 32 || (9...13).contains(code) || (code > 127 && CharacterSet.whitespacesAndNewlines.contains(scalar)) { continue }
            let digit: UInt8
            switch code {
            case 48...57: digit = UInt8(code - 48)
            case 65...70: digit = UInt8(code - 65 + 10)
            case 97...102: digit = UInt8(code - 97 + 10)
            default: return nil
            }
            if let first = high { data.append(first << 4 | digit); high = nil } else { high = digit }
        }
        return high == nil ? data : nil
    }
}
