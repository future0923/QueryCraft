import Foundation

enum RedisKeyspaceInfoParser {
    static func parse(_ info: String) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for line in info.split(whereSeparator: { $0.isNewline }) {
            guard line.hasPrefix("db"),
                  let separator = line.firstIndex(of: ":"),
                  let index = Int(
                      line[
                          line.index(line.startIndex, offsetBy: 2)..<separator
                      ]
                  )
            else { continue }
            let fields = line[line.index(after: separator)...].split(separator: ",")
            guard let keyField = fields.first(where: { $0.hasPrefix("keys=") }),
                  let count = Int(keyField.dropFirst(5))
            else { continue }
            counts[index] = count
        }
        return counts
    }
}
