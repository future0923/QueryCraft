import Foundation

struct SQLExecutionTarget: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case selection
        case currentStatement
        case document
    }

    let kind: Kind
    let source: SQLSourceSnapshot
    let range: SQLSourceRange

    var sql: String {
        (source.text as NSString).substring(with: range.nsRange)
    }
}
