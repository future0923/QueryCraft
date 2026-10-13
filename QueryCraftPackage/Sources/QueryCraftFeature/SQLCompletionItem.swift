import Foundation

struct SQLCompletionItem: Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case keyword
        case function
        case database
        case table
        case view
        case column
        case queryOutput
        case snippet
    }

    let label: String
    let insertionText: String
    let detail: String
    let kind: Kind
    let replacementRange: SQLSourceRange
    let sourceRevision: SQLSourceRevision
    let cursorOffset: Int
    let selectionRanges: [SQLSourceRange]
}

struct SQLCompletionResult: Equatable, Sendable {
    let sourceRevision: SQLSourceRevision
    let windowLocation: Int
    let items: [SQLCompletionItem]
    let referencedSchemaObjects: [WorkspaceSchemaObjectReference]
}
