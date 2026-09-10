import Foundation

struct SQLSourceRange: Equatable, Hashable, Sendable {
    let location: Int
    let length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    var upperBound: Int {
        location + length
    }

    var nsRange: NSRange {
        NSRange(location: location, length: length)
    }

    func contains(_ location: Int) -> Bool {
        location >= self.location && location < upperBound
    }

    func contains(_ range: SQLSourceRange) -> Bool {
        range.location >= location && range.upperBound <= upperBound
    }
}
