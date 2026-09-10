import Foundation

struct SQLRelationReferenceSnapshot: Equatable, Hashable, Sendable {
    let range: SQLSourceRange
    let databaseName: String?
    let objectName: String
    let alias: String?
}
