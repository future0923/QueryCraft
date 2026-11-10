import CloudKit
import Foundation
import GRDB
import Testing
@testable import QueryCraftFeature

struct CloudSyncTests {
    private let zone = CKRecordZone.ID(zoneName: CloudSyncKey.zoneName)

    @Test func connectionRecordRoundTripsWithEncryptedPassword() throws {
        let id = UUID()
        let value = CloudSyncConnection(
            id: id, name: "prod", databaseType: "mysql", host: "db.example", port: 3306,
            username: "root", authenticationMethod: "usernamePassword", defaultDatabase: "shop",
            tlsMode: "required", storesCredential: true, secret: .value("s3cret"),
            desktop: .init(groupID: UUID(), sortIndex: 4, databaseProduct: "mysql",
                           kafkaSASLMechanism: nil, createdAt: Date(timeIntervalSince1970: 10)),
            mobile: .init(schemaName: nil)
        )
        let key = CloudSyncKey(entity: .connection, id: id)
        let record = CKRecord(recordType: key.entity.rawValue, recordID: key.recordID(zoneID: zone))
        CloudSyncRecordCoder.encode(.connection(value), modifiedAt: Date(timeIntervalSince1970: 50), into: record)

        #expect(record["secret"] == nil, "password must not be a plain field")
        #expect(record.encryptedValues["secret"] as? String == "s3cret")
        #expect(CloudSyncRecordCoder.modifiedAt(of: record) == Date(timeIntervalSince1970: 50))
        #expect(try CloudSyncRecordCoder.decode(record) == .connection(value))
    }

    @Test func mobileEditKeepsDesktopOnlyFields() throws {
        let id = UUID(), groupID = UUID()
        let key = CloudSyncKey(entity: .connection, id: id)
        let record = CKRecord(recordType: key.entity.rawValue, recordID: key.recordID(zoneID: zone))
        let desktop = CloudSyncConnection(
            id: id, name: "prod", databaseType: "kafka", host: "k", port: 9092, username: "u",
            authenticationMethod: "usernamePassword", defaultDatabase: nil, tlsMode: "required",
            storesCredential: true, secret: .unavailable,
            desktop: .init(groupID: groupID, sortIndex: 7, databaseProduct: "kafka",
                           kafkaSASLMechanism: "SCRAM-SHA-256", createdAt: .now),
            mobile: nil)
        CloudSyncRecordCoder.encode(.connection(desktop), modifiedAt: .now, into: record)
        var mobile = desktop
        mobile.name = "renamed"; mobile.desktop = nil; mobile.mobile = .init(schemaName: "public")
        CloudSyncRecordCoder.encode(.connection(mobile), modifiedAt: .now, into: record)

        guard case let .connection(decoded) = try CloudSyncRecordCoder.decode(record) else {
            Issue.record("expected a connection"); return
        }
        #expect(decoded.name == "renamed")
        #expect(decoded.desktop?.groupID == groupID)
        #expect(decoded.desktop?.kafkaSASLMechanism == "SCRAM-SHA-256")
        #expect(decoded.mobile?.schemaName == "public")
    }

    @Test func unavailablePasswordKeepsTheStoredSecret() throws {
        let key = CloudSyncKey(entity: .connection, id: UUID())
        let record = CKRecord(recordType: key.entity.rawValue, recordID: key.recordID(zoneID: zone))
        record.encryptedValues["secret"] = "kept" as NSString
        let value = CloudSyncConnection(
            id: key.id, name: "n", databaseType: "postgresql", host: "h", port: 5432, username: "u",
            authenticationMethod: "usernamePassword", defaultDatabase: nil, tlsMode: "required",
            storesCredential: true, secret: .unavailable, desktop: nil, mobile: nil)
        CloudSyncRecordCoder.encode(.connection(value), modifiedAt: .now, into: record)
        #expect(record.encryptedValues["secret"] as? String == "kept")
    }

    @Test func localWritesAreQueuedExceptWhileApplyingRemoteChanges() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profiles = SQLiteConnectionProfileRepository(database: database)
        let metadata = try await database.cloudSyncMetadataStore()
        let local = makeProfile(name: "local")
        try await profiles.insert(local)

        let queued = try metadata.outbox()
        #expect(queued.map(\.key) == [CloudSyncKey(entity: .connection, id: local.id)])
        #expect(queued.first?.isDeletion == false)

        try metadata.completeOutbox(queued[0].key, version: queued[0].version)
        let remote = makeProfile(name: "remote")
        try await database.write { db in
            try withCloudSyncTriggersSuppressed(db) { try remote.insert(db) }
        }
        #expect(try metadata.outbox().isEmpty)

        // Deleting re-normalizes the order of the others; unchanged rows stay quiet.
        try await profiles.delete(id: local.id)
        let afterDelete = try metadata.outbox()
        #expect(afterDelete.map(\.key) == [CloudSyncKey(entity: .connection, id: local.id)])
        #expect(afterDelete.map(\.isDeletion) == [true])
    }

    @Test func outboxCompletionKeepsNewerEdits() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let metadata = try await database.cloudSyncMetadataStore()
        let key = CloudSyncKey(entity: .snippet, id: UUID())
        try metadata.enqueue([key], deleted: false)
        let sent = try #require(try metadata.outboxEntry(for: key))
        try metadata.enqueue([key], deleted: false)
        try metadata.completeOutbox(key, version: sent.version)
        #expect(try metadata.outboxEntry(for: key) != nil, "an edit made during upload must stay queued")
        try metadata.completeOutbox(key, version: sent.version + 1)
        #expect(try metadata.outboxEntry(for: key) == nil)
    }

    @Test func savedQueryWaitsForItsConnectionAndClashingNamesAreRenamed() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profiles = SQLiteConnectionProfileRepository(database: database)
        let profile = makeProfile(name: "p")
        try await profiles.insert(profile)
        try await database.write { db in
            try ConnectionGroup(id: UUID(), name: "Prod", sortIndex: 0, createdAt: .now).insert(db)
        }
        let orphan = CloudSyncSavedQuery(id: UUID(), connectionID: UUID(), defaultDatabase: nil,
                                         name: "q", sql: "SELECT 1", createdAt: .now, updatedAt: .now)
        let remoteGroup = CloudSyncConnectionGroup(id: UUID(), name: "prod", sortIndex: 1, createdAt: .now)
        let query = CloudSyncSavedQuery(id: UUID(), connectionID: profile.id, defaultDatabase: nil,
                                        name: "Daily", sql: "SELECT 2", createdAt: .now, updatedAt: .now)
        let outcome = try await database.write { db in
            try withCloudSyncTriggersSuppressed(db) {
                try DesktopCloudSyncStore.applyRows([
                    .upsert(.connectionGroup(remoteGroup)),
                    .upsert(.savedQuery(orphan)),
                    .upsert(.savedQuery(query)),
                ], in: db)
            }
        }
        #expect(outcome.deferred == [orphan])
        #expect(outcome.renamedGroups == [remoteGroup.id])
        let names = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM connectionGroup ORDER BY sortIndex")
        }
        #expect(names == ["Prod", "prod 2"])
        let stored = try await database.read { db in try SavedQuery.fetchOne(db, key: query.id) }
        #expect(stored?.sql == "SELECT 2")
    }

    @MainActor
    @Test func defaultSnippetsGetTheSameIDsOnEveryDevice() {
        let first = SQLSnippetStore(userDefaults: makeDefaults())
        let second = SQLSnippetStore(userDefaults: makeDefaults())
        #expect(first.snippets.map(\.id) == second.snippets.map(\.id))
        #expect(Set(first.snippets.map(\.id)).count == first.snippets.count)
    }

    @MainActor
    @Test func remoteSnippetsMergeWithoutEchoingBack() throws {
        let store = SQLSnippetStore(userDefaults: makeDefaults())
        var echoed = false
        store.onLocalChange = { _, _ in echoed = true }
        let select = try #require(store.snippets.first { $0.trigger == "sel" })
        let added = CloudSyncSnippet(id: UUID(), name: "explain", trigger: "exp",
                                     content: "EXPLAIN ${s};", isEnabled: true, sortIndex: 99)
        _ = store.applyRemoteChanges(upserts: [added], deletions: [select.id])
        #expect(!echoed)
        #expect(store.snippets.contains { $0.id == added.id && $0.trigger == "exp" })
        #expect(!store.snippets.contains { $0.id == select.id })
        #expect(store.cloudSyncValue(id: added.id)?.content == "EXPLAIN ${s};")
    }

    @Test func deployedSchemaDeclaresEveryWrittenField() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Config/CloudKitSchema.ckdb")
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)
        let id = UUID()
        let values: [CloudSyncValue] = [
            .connectionGroup(.init(id: id, name: "g", sortIndex: 1, createdAt: .now)),
            .connection(.init(id: id, name: "c", databaseType: "kafka", host: "h", port: 1, username: "u",
                              authenticationMethod: "usernamePassword", defaultDatabase: "d", tlsMode: "required",
                              storesCredential: true, secret: .value("p"),
                              desktop: .init(groupID: id, sortIndex: 1, databaseProduct: "kafka",
                                             kafkaSASLMechanism: "PLAIN", createdAt: .now),
                              mobile: .init(schemaName: "s"))),
            .savedQuery(.init(id: id, connectionID: id, defaultDatabase: "d", name: "q", sql: "SELECT 1",
                              createdAt: .now, updatedAt: .now)),
            .snippet(.init(id: id, name: "n", trigger: "t", content: "c", isEnabled: true, sortIndex: 1)),
        ]
        for value in values {
            let record = CKRecord(recordType: value.key.entity.rawValue, recordID: value.key.recordID(zoneID: zone))
            CloudSyncRecordCoder.encode(value, modifiedAt: .now, into: record)
            let start = try #require(schema.range(of: "RECORD TYPE \(value.key.entity.rawValue) ("))
            let block = schema[start.upperBound...].prefix { $0 != ";" }
            for field in record.allKeys() {
                #expect(block.contains("\"\(field)\""), "\(value.key.entity.rawValue).\(field) missing from schema")
            }
            for field in record.encryptedValues.allKeys() {
                #expect(block.range(of: "\"\(field)\"\\s+ENCRYPTED STRING", options: .regularExpression) != nil,
                        "\(value.key.entity.rawValue).\(field) must be encrypted")
            }
        }
    }

    private func makeProfile(name: String) -> ConnectionProfile {
        ConnectionProfile(id: UUID(), name: name, groupID: nil, host: "localhost", port: 3306,
                          username: "root", defaultDatabase: nil, tlsMode: .required,
                          storesCredential: false, createdAt: Date(timeIntervalSince1970: 100))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "CloudSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
