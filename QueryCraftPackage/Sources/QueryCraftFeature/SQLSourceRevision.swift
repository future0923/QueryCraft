import Foundation

struct SQLSourceRevision: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func < (lhs: SQLSourceRevision, rhs: SQLSourceRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SQLSourceSnapshot: Equatable, Sendable {
    let revision: SQLSourceRevision
    let text: String
}

struct SQLSourceEdit: Equatable, Sendable {
    let baseRevision: SQLSourceRevision
    let replacedRange: SQLSourceRange
    let replacement: String
}
