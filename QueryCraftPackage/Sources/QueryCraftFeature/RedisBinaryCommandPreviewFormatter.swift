#if os(iOS)
import QueryCraftMobileCore
#endif
import Foundation

enum RedisBinaryCommandPreviewFormatter {
    static func preview(_ value: RedisBinaryValue, maximumBytes: Int = 4_096) -> String {
        guard value.data.count > maximumBytes else { return escaped(value) }
        return escaped(.init(data: value.data.prefix(max(0, maximumBytes)))) + " <…共 \(value.data.count) 字节，预览已截断>"
    }
    static func escaped(_ value: RedisBinaryValue) -> String {
        if let text = value.losslessUTF8String,
           text.unicodeScalars.allSatisfy({ scalar in
               !CharacterSet.controlCharacters.contains(scalar)
           })
        {
            return RedisCommandPreviewFormatter.escaped(text)
        }
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: value.data.count * 4 + 2) { buffer in
            var offset = 0
            func append(_ byte: UInt8) { buffer[offset] = byte; offset += 1 }
            append(0x22)
            for byte in value.data {
                switch byte {
                case 0x20...0x21, 0x23...0x5B, 0x5D...0x7E: append(byte)
                case 0x22: append(0x5C); append(0x22)
                case 0x5C: append(0x5C); append(0x5C)
                default:
                    append(0x5C); append(0x78); append(digits[Int(byte >> 4)]); append(digits[Int(byte & 15)])
                }
            }
            append(0x22); return offset
        }

    }
}
