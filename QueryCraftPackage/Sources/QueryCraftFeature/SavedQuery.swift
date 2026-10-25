import Foundation
import GRDB

struct SavedQuery: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let connectionProfileID: UUID
    let defaultDatabase: String?
    let name: String
    let sql: String
    let createdAt: Date
    let updatedAt: Date
}

extension SavedQuery: FetchableRecord, PersistableRecord {
    static let databaseTableName = "savedQuery"
}
