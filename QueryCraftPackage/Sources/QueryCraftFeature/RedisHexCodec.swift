import Foundation

enum RedisHexCodec {
    static func format(_ data: Data) -> String {
        data.enumerated().map { index, byte in
            let value = String(format: "%02x", byte)
            return index > 0 && index.isMultiple(of: 16)
                ? "\n\(value)"
                : (index == 0 ? value : " \(value)")
        }.joined()
    }

    static func parse(_ source: String) -> Data? {
        let compact = source.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(String.init).joined()
        guard compact.count.isMultiple(of: 2),
              compact.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                      .contains($0)
              })
        else { return nil }
        var data = Data()
        data.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = end
        }
        return data
    }
}
