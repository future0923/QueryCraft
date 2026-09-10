import Foundation

enum RedisBinaryCommandPreviewFormatter {
    static func escaped(_ value: RedisBinaryValue) -> String {
        if let text = value.losslessUTF8String,
           text.unicodeScalars.allSatisfy({ scalar in
               !CharacterSet.controlCharacters.contains(scalar)
           })
        {
            return RedisCommandPreviewFormatter.escaped(text)
        }
        let content = value.data.map { byte -> String in
            switch byte {
            case 0x20...0x21, 0x23...0x5B, 0x5D...0x7E:
                String(UnicodeScalar(byte))
            case 0x22: "\\\""
            case 0x5C: "\\\\"
            default: String(format: "\\x%02x", byte)
            }
        }.joined()
        return "\"\(content)\""
    }
}
