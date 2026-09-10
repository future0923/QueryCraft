import Foundation
import GRDB

struct ConnectionGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let sortIndex: Int
    let createdAt: Date
}

extension ConnectionGroup: FetchableRecord, PersistableRecord {
    static let databaseTableName = "connectionGroup"
}
