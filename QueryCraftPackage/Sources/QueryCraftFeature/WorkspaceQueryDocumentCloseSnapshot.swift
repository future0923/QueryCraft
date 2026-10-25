import Foundation

struct WorkspaceQueryDocumentCloseSnapshot: Equatable, Sendable {
    let sql: String
    let databaseName: String?
}
