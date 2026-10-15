import Foundation
import GRDB

struct MCPCallRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "mcpCall"
    let id: String
    let startedAt: Date
    let tool: String
    let connectionID: String?
    let durationMilliseconds: Int
    let succeeded: Bool
    let errorCode: String?
    let resultBytes: Int
}

/// Stores operational metadata only: never SQL, arguments, credentials, errors or result bodies.
/// SQLite serializes the independent stdio/HTTP processes with the desktop reader.
actor MCPHistoryStore {
    let directory: URL
    private var queue: DatabaseQueue?
    init(directory: URL) { self.directory = directory.appending(path: "MCP/History") }
    private func database() throws -> DatabaseQueue {
        if let queue { return queue }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "calls.sqlite")
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mcpCall (
                    id TEXT PRIMARY KEY, startedAt DATETIME NOT NULL, tool TEXT NOT NULL,
                    connectionID TEXT, durationMilliseconds INTEGER NOT NULL,
                    succeeded BOOLEAN NOT NULL, errorCode TEXT, resultBytes INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS mcpCall_startedAt ON mcpCall(startedAt);
                """)
        }
        self.queue = queue
        return queue
    }
    func append(_ record: MCPCallRecord) throws {
        try database().write { db in
            try record.insert(db)
            try db.execute(sql: "DELETE FROM mcpCall WHERE id NOT IN (SELECT id FROM mcpCall ORDER BY startedAt DESC, id DESC LIMIT 500)")
        }
    }
    func recent(limit: Int = 100) throws -> [MCPCallRecord] {
        try database().read { db in
            try MCPCallRecord.order(Column("startedAt").desc, Column("id").desc).limit(min(500, max(1, limit))).fetchAll(db)
        }
    }
    func clear() throws { try database().write { db in _ = try MCPCallRecord.deleteAll(db) } }
}
