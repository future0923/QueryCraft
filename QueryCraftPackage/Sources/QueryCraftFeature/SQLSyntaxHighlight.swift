import Foundation

struct SQLSyntaxHighlight: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyword
        case comment
        case variable
        case property
        case function
        case number
        case string
        case type
        case parameter
        case boolean
        case attribute
    }

    let range: SQLSourceRange
    let kind: Kind
}
