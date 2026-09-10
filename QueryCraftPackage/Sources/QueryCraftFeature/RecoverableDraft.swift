import Foundation
import GRDB

struct RecoverableDraft: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let connectionProfileID: ConnectionProfile.ID
    let defaultDatabase: String?
    let sql: String
    let createdAt: Date
    let updatedAt: Date
}

extension RecoverableDraft: FetchableRecord, PersistableRecord {
    static let databaseTableName = "recoverableDraft"
}
