import CloudKit
import Foundation
import GRDB

struct CloudSyncOutboxEntry: Equatable, Sendable {
    let key: CloudSyncKey
    let isDeletion: Bool
    let changedAt: Date
    let version: Int
}

/// Sync bookkeeping kept next to local data:
/// - `cloudSyncOutbox`: local changes not yet confirmed by iCloud.
/// - `cloudSyncRecord`: CloudKit system fields (change tags) per record.
/// - `cloudSyncDeferred`: remote values waiting for a parent (a saved query
///   whose connection has not arrived yet).
/// - `cloudSyncState`: CKSyncEngine serialization and settings.
/// Secrets never enter these tables.
struct CloudSyncMetadataStore: Sendable {
    let writer: any DatabaseWriter

    /// Opens a dedicated bookkeeping database, for platforms whose local data
    /// is not stored in SQLite (iPhone and iPad).
    static func standalone(at url: URL) throws -> CloudSyncMetadataStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try createTables(in: db) }
        return CloudSyncMetadataStore(writer: queue)
    }

    static func createTables(in db: Database) throws {
        try db.create(table: "cloudSyncState", options: .ifNotExists) { table in
            table.primaryKey("key", .text).notNull()
            table.column("value", .blob)
        }
        try db.create(table: "cloudSyncOutbox", options: .ifNotExists) { table in
            table.column("entity", .text).notNull()
            table.column("entityID", .blob).notNull()
            table.column("deleted", .integer).notNull().defaults(to: 0)
            table.column("changedAt", .integer).notNull()
            table.column("version", .integer).notNull().defaults(to: 1)
            table.primaryKey(["entity", "entityID"])
        }
        try db.create(table: "cloudSyncRecord", options: .ifNotExists) { table in
            table.primaryKey("recordName", .text).notNull()
            table.column("systemFields", .blob).notNull()
        }
        try db.create(table: "cloudSyncDeferred", options: .ifNotExists) { table in
            table.primaryKey("recordName", .text).notNull()
            table.column("payload", .blob).notNull()
        }
        try db.create(table: "cloudSyncApplying", options: .ifNotExists) { table in
            table.column("marker", .integer).notNull()
        }
    }

    /// SQL expression for "now" in Unix milliseconds, usable in triggers.
    static let nowMillisecondsSQL = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)"

    /// Records every local change to `table` in the outbox, from any process
    /// that writes the database (desktop app, MCP), except while remote
    /// changes are being applied.
    static func createOutboxTriggers(
        in db: Database,
        table: String,
        entity: CloudSyncEntity
    ) throws {
        let upsert = """
            INSERT INTO cloudSyncOutbox(entity, entityID, deleted, changedAt, version)
            VALUES ('\(entity.rawValue)', %@.id, %d, \(nowMillisecondsSQL), 1)
            ON CONFLICT(entity, entityID) DO UPDATE SET
                deleted = excluded.deleted,
                changedAt = excluded.changedAt,
                version = cloudSyncOutbox.version + 1;
            """
        let guardClause = "WHEN NOT EXISTS (SELECT 1 FROM cloudSyncApplying)"
        // Rewrites that leave a row unchanged (for example re-normalizing
        // every sort index) must not re-upload it over other devices' edits.
        let columns = try db.columns(in: table).map(\.name)
        let changed = columns
            .map { "OLD.\"\($0)\" IS NOT NEW.\"\($0)\"" }
            .joined(separator: " OR ")
        for (event, row, deleted) in [("INSERT", "NEW", 0), ("UPDATE", "NEW", 0), ("DELETE", "OLD", 1)] {
            let name = "cloudSync_\(table)_\(event.lowercased())"
            let condition = event == "UPDATE" ? "\(guardClause) AND (\(changed))" : guardClause
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)")
            try db.execute(sql: """
                CREATE TRIGGER \(name) AFTER \(event) ON \(table)
                \(condition)
                BEGIN
                \(String(format: upsert, row, deleted))
                END
                """)
        }
    }

    // MARK: Outbox

    func outbox() throws -> [CloudSyncOutboxEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT entity, entityID, deleted, changedAt, version
                FROM cloudSyncOutbox ORDER BY changedAt
                """).compactMap(Self.outboxEntry)
        }
    }

    func outboxEntry(for key: CloudSyncKey) throws -> CloudSyncOutboxEntry? {
        try writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT entity, entityID, deleted, changedAt, version
                FROM cloudSyncOutbox WHERE entity = ? AND entityID = ?
                """, arguments: [key.entity.rawValue, key.id]).flatMap(Self.outboxEntry)
        }
    }

    /// Records a local change. `replaceExisting == false` keeps an existing
    /// entry (used for the initial upload, which must not mask newer edits).
    func enqueue(
        _ keys: [CloudSyncKey],
        deleted: Bool,
        changedAt: Date = .now,
        replaceExisting: Bool = true
    ) throws {
        guard !keys.isEmpty else { return }
        try writer.write { db in
            for key in keys {
                let conflict = replaceExisting
                    ? """
                      DO UPDATE SET deleted = excluded.deleted, changedAt = excluded.changedAt,
                          version = cloudSyncOutbox.version + 1
                      """
                    : "DO NOTHING"
                try db.execute(sql: """
                    INSERT INTO cloudSyncOutbox(entity, entityID, deleted, changedAt, version)
                    VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(entity, entityID) \(conflict)
                    """, arguments: [key.entity.rawValue, key.id, deleted, Self.milliseconds(changedAt)])
            }
        }
    }

    /// Removes the entry only if no newer local change happened meanwhile.
    func completeOutbox(_ key: CloudSyncKey, version: Int?) throws {
        try writer.write { db in
            if let version {
                try db.execute(sql: """
                    DELETE FROM cloudSyncOutbox WHERE entity = ? AND entityID = ? AND version = ?
                    """, arguments: [key.entity.rawValue, key.id, version])
            } else {
                try db.execute(sql: """
                    DELETE FROM cloudSyncOutbox WHERE entity = ? AND entityID = ?
                    """, arguments: [key.entity.rawValue, key.id])
            }
        }
    }

    // MARK: Server system fields

    func systemFieldsRecord(for key: CloudSyncKey) throws -> CKRecord? {
        let data = try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT systemFields FROM cloudSyncRecord WHERE recordName = ?",
                              arguments: [key.recordName])
        }
        guard let data else { return nil }
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    func saveSystemFields(of record: CKRecord) throws {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        let data = coder.encodedData
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO cloudSyncRecord(recordName, systemFields) VALUES (?, ?)
                ON CONFLICT(recordName) DO UPDATE SET systemFields = excluded.systemFields
                """, arguments: [record.recordID.recordName, data])
        }
    }

    func removeSystemFields(for key: CloudSyncKey) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM cloudSyncRecord WHERE recordName = ?", arguments: [key.recordName])
        }
    }

    // MARK: Deferred remote values

    func deferSavedQuery(_ query: CloudSyncSavedQuery) throws {
        let data = try JSONEncoder().encode(CloudSyncDeferredSavedQuery(query))
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO cloudSyncDeferred(recordName, payload) VALUES (?, ?)
                ON CONFLICT(recordName) DO UPDATE SET payload = excluded.payload
                """, arguments: [CloudSyncKey(entity: .savedQuery, id: query.id).recordName, data])
        }
    }

    func deferredSavedQueries() throws -> [CloudSyncSavedQuery] {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM cloudSyncDeferred")
        }.compactMap { try? JSONDecoder().decode(CloudSyncDeferredSavedQuery.self, from: $0).value }
    }

    func removeDeferred(_ key: CloudSyncKey) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM cloudSyncDeferred WHERE recordName = ?", arguments: [key.recordName])
        }
    }

    // MARK: State

    func state(_ key: String) throws -> Data? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM cloudSyncState WHERE key = ?", arguments: [key])
        }
    }

    func setState(_ value: Data?, for key: String) throws {
        try writer.write { db in
            if let value {
                try db.execute(sql: """
                    INSERT INTO cloudSyncState(key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM cloudSyncState WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Forgets everything known about iCloud while keeping local data and
    /// pending local edits; the next start performs a full merge.
    func resetServerState() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM cloudSyncRecord")
            try db.execute(sql: "DELETE FROM cloudSyncDeferred")
            try db.execute(sql: "DELETE FROM cloudSyncState WHERE key = ?", arguments: [Self.engineStateKey])
        }
    }

    static let engineStateKey = "engineState"

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func outboxEntry(_ row: Row) -> CloudSyncOutboxEntry? {
        guard let entity = CloudSyncEntity(rawValue: row["entity"]),
              let id = row["entityID"] as UUID?
        else { return nil }
        let milliseconds: Int64 = row["changedAt"]
        return CloudSyncOutboxEntry(
            key: .init(entity: entity, id: id),
            isDeletion: row["deleted"],
            changedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
            version: row["version"]
        )
    }
}

/// Runs `body` so that the outbox triggers ignore its writes.
func withCloudSyncTriggersSuppressed<T>(_ db: Database, _ body: () throws -> T) throws -> T {
    try db.execute(sql: "INSERT INTO cloudSyncApplying(marker) VALUES (1)")
    defer { try? db.execute(sql: "DELETE FROM cloudSyncApplying") }
    return try body()
}

private struct CloudSyncDeferredSavedQuery: Codable {
    let id: UUID
    let connectionID: UUID
    let defaultDatabase: String?
    let name: String
    let sql: String
    let createdAt: Date
    let updatedAt: Date

    init(_ query: CloudSyncSavedQuery) {
        id = query.id
        connectionID = query.connectionID
        defaultDatabase = query.defaultDatabase
        name = query.name
        sql = query.sql
        createdAt = query.createdAt
        updatedAt = query.updatedAt
    }

    var value: CloudSyncSavedQuery {
        .init(id: id, connectionID: connectionID, defaultDatabase: defaultDatabase,
              name: name, sql: sql, createdAt: createdAt, updatedAt: updatedAt)
    }
}
