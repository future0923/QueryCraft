import Foundation

struct SQLFormattingEdit: Equatable, Sendable {
    let sourceRevision: SQLSourceRevision
    let range: SQLSourceRange
    let replacement: String
    let selectedRange: NSRange
}
