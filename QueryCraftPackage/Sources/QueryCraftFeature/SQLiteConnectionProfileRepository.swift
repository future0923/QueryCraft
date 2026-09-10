import Foundation
import GRDB

struct SQLiteConnectionProfileRepository: ConnectionManagementRepository {
    private let database: SQLiteApplicationDatabase

    init(database: SQLiteApplicationDatabase = .shared) {
        self.database = database
    }

    init(databaseURL: URL?) {
        database = SQLiteApplicationDatabase(databaseURL: databaseURL)
    }

    func fetchAll() async throws -> [ConnectionProfile] {
        try await database.read { database in
            try ConnectionProfile
                .order(Column("name").collating(.nocase))
                .fetchAll(database)
        }
    }

    func fetch(id: ConnectionProfile.ID) async throws -> ConnectionProfile? {
        try await database.read { database in
            try ConnectionProfile.fetchOne(database, key: id)
        }
    }

    func insert(_ profile: ConnectionProfile) async throws {
        try await database.write { database in
            try profile.insert(database)
        }
    }

    func update(_ profile: ConnectionProfile) async throws {
        try await database.write { database in
            try profile.update(database)
            try Self.normalizeProfileOrder(in: database)
        }
    }

    func delete(id: ConnectionProfile.ID) async throws {
        try await deleteProfiles(ids: [id])
    }

    func fetchManagementSnapshot() async throws -> ConnectionManagementSnapshot {
        try await database.read { database in
            let groups = try ConnectionGroup
                .order(
                    Column("sortIndex"),
                    Column("name").collating(.nocase)
                )
                .fetchAll(database)
            let profiles = try ConnectionProfile
                .order(
                    Column("groupID"),
                    Column("sortIndex"),
                    Column("name").collating(.nocase)
                )
                .fetchAll(database)
            return ConnectionManagementSnapshot(
                groups: groups,
                profiles: profiles
            )
        }
    }

    func insert(_ group: ConnectionGroup) async throws {
        try await database.write { database in
            try group.insert(database)
        }
    }

    func update(_ group: ConnectionGroup) async throws {
        try await database.write { database in
            try group.update(database)
        }
    }

    func deletionImpact(
        profileIDs: [ConnectionProfile.ID]
    ) async throws -> ConnectionDeletionImpact {
        try await database.read { database in
            try Self.deletionImpact(
                profileIDs: profileIDs,
                in: database
            )
        }
    }

    func deleteProfiles(ids: [ConnectionProfile.ID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.write { database in
            for id in ids {
                _ = try ConnectionProfile.deleteOne(database, key: id)
            }
            try Self.normalizeProfileOrder(in: database)
        }
    }

    func deleteGroup(id: ConnectionGroup.ID) async throws {
        try await database.write { database in
            _ = try ConnectionGroup.deleteOne(database, key: id)
            try Self.normalizeGroupOrder(in: database)
        }
    }

    func moveProfile(
        id: ConnectionProfile.ID,
        toGroupID: ConnectionGroup.ID?,
        beforeProfileID: ConnectionProfile.ID?
    ) async throws {
        try await database.write { database in
            guard let profile = try ConnectionProfile.fetchOne(
                database,
                key: id
            ) else {
                return
            }
            if let toGroupID {
                guard try ConnectionGroup.fetchOne(
                    database,
                    key: toGroupID
                ) != nil else {
                    return
                }
            }

            let destinationIDs = try Self.profileIDs(
                in: toGroupID,
                database: database
            ).filter { $0 != id }
            let insertionIndex = beforeProfileID.flatMap {
                destinationIDs.firstIndex(of: $0)
            } ?? destinationIDs.endIndex
            var orderedDestinationIDs = destinationIDs
            orderedDestinationIDs.insert(id, at: insertionIndex)

            try database.execute(
                sql: """
                    UPDATE connectionProfile
                    SET groupID = ?
                    WHERE id = ?
                    """,
                arguments: [toGroupID, id]
            )
            try Self.writeProfileOrder(
                orderedDestinationIDs,
                in: database
            )
            if profile.groupID != toGroupID {
                try Self.writeProfileOrder(
                    Self.profileIDs(
                        in: profile.groupID,
                        database: database
                    ),
                    in: database
                )
            }
        }
    }

    func moveGroup(
        id: ConnectionGroup.ID,
        beforeGroupID: ConnectionGroup.ID?
    ) async throws {
        try await database.write { database in
            var ids = try ConnectionGroup
                .order(
                    Column("sortIndex"),
                    Column("name").collating(.nocase)
                )
                .select(Column("id"))
                .asRequest(of: UUID.self)
                .fetchAll(database)
            guard ids.contains(id) else { return }
            ids.removeAll { $0 == id }
            let insertionIndex = beforeGroupID.flatMap {
                ids.firstIndex(of: $0)
            } ?? ids.endIndex
            ids.insert(id, at: insertionIndex)
            for (sortIndex, groupID) in ids.enumerated() {
                try database.execute(
                    sql: """
                        UPDATE connectionGroup
                        SET sortIndex = ?
                        WHERE id = ?
                        """,
                    arguments: [sortIndex, groupID]
                )
            }
        }
    }

    private static func deletionImpact(
        profileIDs: [ConnectionProfile.ID],
        in database: Database
    ) throws -> ConnectionDeletionImpact {
        var savedQueryCount = 0
        var recoverableDraftCount = 0
        var workspaceRestorationCount = 0
        var storedCredentialCount = 0
        var existingProfileCount = 0

        for profileID in profileIDs {
            if let profile = try ConnectionProfile.fetchOne(
                database,
                key: profileID
            ) {
                existingProfileCount += 1
                storedCredentialCount += profile.storesCredential ? 1 : 0
            }
            savedQueryCount += try SavedQuery
                .filter(Column("connectionProfileID") == profileID)
                .fetchCount(database)
            recoverableDraftCount += try RecoverableDraft
                .filter(Column("connectionProfileID") == profileID)
                .fetchCount(database)
            workspaceRestorationCount += try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM workspaceRestoration
                    WHERE connectionProfileID = ?
                    """,
                arguments: [profileID]
            ) ?? 0
        }

        return ConnectionDeletionImpact(
            connectionProfileCount: existingProfileCount,
            savedQueryCount: savedQueryCount,
            recoverableDraftCount: recoverableDraftCount,
            workspaceRestorationCount: workspaceRestorationCount,
            storedCredentialCount: storedCredentialCount
        )
    }

    private static func profileIDs(
        in groupID: ConnectionGroup.ID?,
        database: Database
    ) throws -> [ConnectionProfile.ID] {
        var request = ConnectionProfile.order(
            Column("sortIndex"),
            Column("name").collating(.nocase)
        )
        if let groupID {
            request = request.filter(Column("groupID") == groupID)
        } else {
            request = request.filter(Column("groupID") == nil)
        }
        return try request
            .select(Column("id"))
            .asRequest(of: UUID.self)
            .fetchAll(database)
    }

    private static func writeProfileOrder(
        _ profileIDs: [ConnectionProfile.ID],
        in database: Database
    ) throws {
        for (sortIndex, profileID) in profileIDs.enumerated() {
            try database.execute(
                sql: """
                    UPDATE connectionProfile
                    SET sortIndex = ?
                    WHERE id = ?
                    """,
                arguments: [sortIndex, profileID]
            )
        }
    }

    private static func normalizeProfileOrder(
        in database: Database
    ) throws {
        let groupIDs = try ConnectionGroup
            .select(Column("id"))
            .asRequest(of: UUID.self)
            .fetchAll(database)
        try writeProfileOrder(
            profileIDs(in: nil, database: database),
            in: database
        )
        for groupID in groupIDs {
            try writeProfileOrder(
                profileIDs(in: groupID, database: database),
                in: database
            )
        }
    }

    private static func normalizeGroupOrder(
        in database: Database
    ) throws {
        let groupIDs = try ConnectionGroup
            .order(
                Column("sortIndex"),
                Column("name").collating(.nocase)
            )
            .select(Column("id"))
            .asRequest(of: UUID.self)
            .fetchAll(database)
        for (sortIndex, groupID) in groupIDs.enumerated() {
            try database.execute(
                sql: """
                    UPDATE connectionGroup
                    SET sortIndex = ?
                    WHERE id = ?
                    """,
                arguments: [sortIndex, groupID]
            )
        }
    }
}
