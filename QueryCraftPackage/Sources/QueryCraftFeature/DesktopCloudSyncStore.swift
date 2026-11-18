import Foundation
import GRDB

/// macOS storage for iCloud sync: SQLite (connections, groups, saved
/// queries), the credential vault (passwords) and preferences (snippets).
/// Local edits reach the outbox through SQLite triggers, so changes made by
/// the MCP process are uploaded too.
struct DesktopCloudSyncStore: CloudSyncLocalStore {
    let database: SQLiteApplicationDatabase
    let metadata: CloudSyncMetadataStore
    let credentials: any CredentialStore
    let snippets: @MainActor @Sendable () -> SQLSnippetStore

    func value(for key: CloudSyncKey) async throws -> CloudSyncValue? {
        switch key.entity {
        case .connectionGroup:
            return try await database.read { db in try ConnectionGroup.fetchOne(db, key: key.id) }
                .map { .connectionGroup(.init(id: $0.id, name: $0.name, sortIndex: $0.sortIndex, createdAt: $0.createdAt)) }
        case .connection:
            guard let profile = try await database.read({ db in try ConnectionProfile.fetchOne(db, key: key.id) }) else {
                return nil
            }
            return .connection(Self.connection(from: profile, secret: await secret(for: profile)))
        case .savedQuery:
            return try await database.read { db in try SavedQuery.fetchOne(db, key: key.id) }
                .map { .savedQuery(.init(id: $0.id, connectionID: $0.connectionProfileID, defaultDatabase: $0.defaultDatabase,
                                         name: $0.name, sql: $0.sql, createdAt: $0.createdAt, updatedAt: $0.updatedAt)) }
        case .snippet:
            return await MainActor.run { snippets().cloudSyncValue(id: key.id) }.map(CloudSyncValue.snippet)
        }
    }

    func allKeys() async throws -> [CloudSyncKey] {
        let stored = try await database.read { db -> [CloudSyncKey] in
            let groups = try UUID.fetchAll(db, sql: "SELECT id FROM connectionGroup")
            let profiles = try UUID.fetchAll(db, sql: "SELECT id FROM connectionProfile")
            let queries = try UUID.fetchAll(db, sql: "SELECT id FROM savedQuery")
            return groups.map { CloudSyncKey(entity: .connectionGroup, id: $0) }
                + profiles.map { CloudSyncKey(entity: .connection, id: $0) }
                + queries.map { CloudSyncKey(entity: .savedQuery, id: $0) }
        }
        let snippetIDs = await MainActor.run { snippets().snippets.map(\.id) }
        return stored + snippetIDs.map { CloudSyncKey(entity: .snippet, id: $0) }
    }

    func apply(_ changes: [CloudSyncRemoteChange]) async throws -> [CloudSyncSavedQuery] {
        let outcome = try await database.write { db in
            try withCloudSyncTriggersSuppressed(db) { try Self.applyRows(changes, in: db) }
        }
        for (profileID, secret) in outcome.secrets {
            do {
                if let secret { try await credentials.save(password: secret, for: profileID) }
                else { try await credentials.delete(for: profileID) }
            } catch {
                // The connection stays usable; the user is asked for the password.
            }
        }
        let snippetUpserts = changes.compactMap { change -> CloudSyncSnippet? in
            if case let .upsert(.snippet(snippet)) = change { return snippet }
            return nil
        }
        let snippetDeletions = changes.compactMap { change -> UUID? in
            if case let .delete(key) = change, key.entity == .snippet { return key.id }
            return nil
        }
        if !snippetUpserts.isEmpty || !snippetDeletions.isEmpty {
            let followUp = await MainActor.run {
                snippets().applyRemoteChanges(upserts: snippetUpserts, deletions: snippetDeletions)
            }
            try metadata.enqueue(followUp.changed.map { .init(entity: .snippet, id: $0) }, deleted: false)
            try metadata.enqueue(followUp.deleted.map { .init(entity: .snippet, id: $0) }, deleted: true)
        }
        if !outcome.renamedQueries.isEmpty {
            try metadata.enqueue(outcome.renamedQueries.map { .init(entity: .savedQuery, id: $0) }, deleted: false)
        }
        if !outcome.renamedGroups.isEmpty {
            try metadata.enqueue(outcome.renamedGroups.map { .init(entity: .connectionGroup, id: $0) }, deleted: false)
        }
        return outcome.deferred
    }

    // MARK: Mapping

    static func connection(from profile: ConnectionProfile, secret: CloudSyncSecret) -> CloudSyncConnection {
        CloudSyncConnection(
            id: profile.id,
            name: profile.name,
            databaseType: profile.databaseType.rawValue,
            host: profile.host,
            port: profile.port,
            username: profile.username,
            authenticationMethod: profile.authenticationMethod.rawValue,
            defaultDatabase: profile.defaultDatabase,
            tlsMode: profile.tlsMode.rawValue,
            storesCredential: profile.storesCredential,
            secret: profile.storesCredential ? secret : .none,
            desktop: .init(
                groupID: profile.groupID,
                sortIndex: profile.sortIndex,
                databaseProduct: profile.databaseProduct.rawValue,
                kafkaSASLMechanism: profile.kafkaSASLMechanism?.rawValue,
                createdAt: profile.createdAt
            ),
            mobile: nil
        )
    }

    static func profile(from connection: CloudSyncConnection, existingGroupID: (UUID) -> Bool) -> ConnectionProfile? {
        guard let databaseType = DatabaseType(rawValue: connection.databaseType),
              let tlsMode = ConnectionTLSMode(rawValue: connection.tlsMode),
              (1...65_535).contains(connection.port)
        else { return nil }
        let product = connection.desktop
            .flatMap { DatabaseProduct(rawValue: $0.databaseProduct) }
            .flatMap { $0.databaseType == databaseType ? $0 : nil }
        let groupID = connection.desktop?.groupID.flatMap { existingGroupID($0) ? $0 : nil }
        return ConnectionProfile(
            id: connection.id,
            name: connection.name,
            groupID: groupID,
            databaseType: databaseType,
            databaseProduct: product,
            host: connection.host,
            port: connection.port,
            username: connection.username,
            authenticationMethod: DatabaseConnectionAuthenticationMethod(rawValue: connection.authenticationMethod)
                ?? .usernamePassword,
            kafkaSASLMechanism: databaseType == .kafka
                ? connection.desktop?.kafkaSASLMechanism.flatMap(KafkaSASLMechanism.init(rawValue:)) : nil,
            defaultDatabase: connection.defaultDatabase.flatMap { $0.isEmpty ? nil : $0 },
            tlsMode: tlsMode,
            storesCredential: connection.storesCredential,
            sortIndex: connection.desktop?.sortIndex ?? Int.max / 2,
            createdAt: connection.desktop?.createdAt ?? .now
        )
    }

    private func secret(for profile: ConnectionProfile) async -> CloudSyncSecret {
        guard profile.storesCredential, profile.authenticationMethod != .none else { return .none }
        do {
            guard let password = try await credentials.password(for: profile.id), !password.isEmpty else { return .none }
            return .value(password)
        } catch {
            return .unavailable
        }
    }

    // MARK: Applying rows

    struct ApplyOutcome: Sendable {
        var deferred: [CloudSyncSavedQuery] = []
        /// nil removes the stored password.
        var secrets: [(UUID, String?)] = []
        var renamedQueries: [UUID] = []
        var renamedGroups: [UUID] = []
    }

    static func applyRows(_ changes: [CloudSyncRemoteChange], in db: Database) throws -> ApplyOutcome {
        var outcome = ApplyOutcome()
        for change in changes {
            switch change {
            case let .delete(key):
                switch key.entity {
                case .connectionGroup:
                    _ = try ConnectionGroup.deleteOne(db, key: key.id)
                case .connection:
                    if try ConnectionProfile.deleteOne(db, key: key.id) {
                        outcome.secrets.append((key.id, nil))
                    }
                case .savedQuery:
                    _ = try SavedQuery.deleteOne(db, key: key.id)
                case .snippet:
                    break
                }
            case let .upsert(.connectionGroup(group)):
                var name = group.name
                if try conflictingGroupExists(name: name, id: group.id, in: db) {
                    name = try uniqueGroupName(group.name, id: group.id, in: db)
                    outcome.renamedGroups.append(group.id)
                }
                try ConnectionGroup(id: group.id, name: name, sortIndex: group.sortIndex, createdAt: group.createdAt).save(db)
            case let .upsert(.connection(connection)):
                guard let profile = profile(from: connection, existingGroupID: { id in
                    (try? ConnectionGroup.exists(db, key: id)) ?? false
                }) else { continue }
                try profile.save(db)
                switch connection.secret {
                case let .value(secret) where connection.storesCredential:
                    outcome.secrets.append((connection.id, secret))
                case .unavailable:
                    break
                default:
                    if !connection.storesCredential { outcome.secrets.append((connection.id, nil)) }
                }
            case let .upsert(.savedQuery(query)):
                guard try ConnectionProfile.exists(db, key: query.connectionID) else {
                    outcome.deferred.append(query)
                    continue
                }
                var name = query.name
                if try conflictingQueryExists(name: name, query: query, in: db) {
                    name = try uniqueQueryName(query, in: db)
                    outcome.renamedQueries.append(query.id)
                }
                try SavedQuery(id: query.id, connectionProfileID: query.connectionID, defaultDatabase: query.defaultDatabase,
                               name: name, sql: query.sql, createdAt: query.createdAt, updatedAt: query.updatedAt).save(db)
            case .upsert(.snippet):
                break
            }
        }
        return outcome
    }

    private static func conflictingGroupExists(name: String, id: UUID, in db: Database) throws -> Bool {
        try ConnectionGroup.filter(Column("name").collating(.nocase) == name && Column("id") != id).fetchCount(db) > 0
    }

    private static func uniqueGroupName(_ base: String, id: UUID, in db: Database) throws -> String {
        var suffix = 2
        while try conflictingGroupExists(name: "\(base) \(suffix)", id: id, in: db) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private static func conflictingQueryExists(name: String, query: CloudSyncSavedQuery, in db: Database) throws -> Bool {
        var request = SavedQuery.filter(Column("connectionProfileID") == query.connectionID
            && Column("name") == name && Column("id") != query.id)
        request = query.defaultDatabase.map { request.filter(Column("defaultDatabase") == $0) }
            ?? request.filter(Column("defaultDatabase") == nil)
        return try request.fetchCount(db) > 0
    }

    private static func uniqueQueryName(_ query: CloudSyncSavedQuery, in db: Database) throws -> String {
        var suffix = 2
        while try conflictingQueryExists(name: "\(query.name) \(suffix)", query: query, in: db) { suffix += 1 }
        return "\(query.name) \(suffix)"
    }
}
