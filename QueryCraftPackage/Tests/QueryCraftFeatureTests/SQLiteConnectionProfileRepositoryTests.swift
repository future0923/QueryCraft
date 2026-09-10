import Foundation
import GRDB
import Testing
@testable import QueryCraftFeature

struct SQLiteConnectionProfileRepositoryTests {
    @Test func insertsAndFetchesProfilesByName() async throws {
        let repository = SQLiteConnectionProfileRepository(databaseURL: nil)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let group = ConnectionGroup(
            id: UUID(),
            name: "Development",
            sortIndex: 0,
            createdAt: createdAt
        )
        let second = ConnectionProfile(
            id: UUID(),
            name: "Staging",
            groupID: nil,
            databaseType: .postgresql,
            host: "staging.example.com",
            port: 3306,
            username: "developer",
            defaultDatabase: nil,
            tlsMode: .verifyIdentity,
            storesCredential: false,
            createdAt: createdAt
        )
        let first = ConnectionProfile(
            id: UUID(),
            name: "Local",
            groupID: group.id,
            host: "localhost",
            port: 3306,
            username: "root",
            defaultDatabase: "querycraft",
            tlsMode: .required,
            storesCredential: true,
            createdAt: createdAt
        )

        try await repository.insert(group)
        try await repository.insert(second)
        try await repository.insert(first)

        let profiles = try await repository.fetchAll()
        #expect(profiles == [first, second])
    }

    @Test func migratesBaselineDatabaseWithoutLosingProfiles() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(
                path: "QueryCraftPersistenceTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let databaseURL = directoryURL.appending(path: "QueryCraft.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let profile = ConnectionProfile(
            id: UUID(),
            name: "Baseline",
            groupID: nil,
            host: "localhost",
            port: 3306,
            username: "root",
            defaultDatabase: "querycraft",
            tlsMode: .required,
            storesCredential: false,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let lowercaseGroupProfileID = UUID()
        let baselineQueue = try DatabaseQueue(path: databaseURL.path)
        var baselineMigrator = DatabaseMigrator()
        baselineMigrator.registerMigration(
            "createConnectionProfile"
        ) { database in
            try database.create(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.primaryKey("id", .text).notNull()
                table.column("name", .text).notNull()
                table.column("groupName", .text)
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("username", .text).notNull()
                table.column("defaultDatabase", .text)
                table.column("storesCredential", .boolean).notNull()
                table.column("createdAt", .datetime).notNull()
            }
        }
        baselineMigrator.registerMigration(
            "addConnectionTLSMode"
        ) { database in
            try database.alter(
                table: ConnectionProfile.databaseTableName
            ) { table in
                table.add(column: "tlsMode", .text)
                    .notNull()
                    .defaults(
                        to: ConnectionTLSMode.verifyIdentity.rawValue
                    )
            }
        }
        try baselineMigrator.migrate(baselineQueue)
        try await baselineQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO connectionProfile (
                        id,
                        name,
                        groupName,
                        host,
                        port,
                        username,
                        defaultDatabase,
                        storesCredential,
                        createdAt,
                        tlsMode
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    profile.id,
                    profile.name,
                    "Development",
                    profile.host,
                    profile.port,
                    profile.username,
                    profile.defaultDatabase,
                    profile.storesCredential,
                    profile.createdAt,
                    profile.tlsMode.rawValue,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO connectionProfile (
                        id,
                        name,
                        groupName,
                        host,
                        port,
                        username,
                        defaultDatabase,
                        storesCredential,
                        createdAt,
                        tlsMode
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    lowercaseGroupProfileID,
                    "Secondary",
                    "development",
                    "secondary.example.com",
                    3306,
                    "developer",
                    nil,
                    false,
                    profile.createdAt,
                    ConnectionTLSMode.verifyIdentity.rawValue,
                ]
            )
        }
        try baselineQueue.close()

        let database = SQLiteApplicationDatabase(databaseURL: databaseURL)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let queryRepository = SQLiteSavedQueryRepository(database: database)
        let query = SavedQuery(
            id: UUID(),
            connectionProfileID: profile.id,
            defaultDatabase: nil,
            name: "Health Check",
            sql: "SELECT 1;",
            createdAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let migratedProfile = try #require(
            try await profileRepository.fetch(id: profile.id)
        )
        #expect(migratedProfile.name == profile.name)
        #expect(migratedProfile.databaseType == .mysql)
        #expect(migratedProfile.databaseProduct == .mysql)
        #expect(migratedProfile.authenticationMethod == .usernamePassword)
        #expect(migratedProfile.groupID != nil)
        let snapshot = try await profileRepository.fetchManagementSnapshot()
        #expect(snapshot.groups.map(\.name) == ["Development"])
        #expect(snapshot.groups.first?.id == migratedProfile.groupID)
        #expect(
            try await profileRepository.fetch(
                id: lowercaseGroupProfileID
            )?.groupID == migratedProfile.groupID
        )
        try await queryRepository.insert(query)
        #expect(try await queryRepository.fetch(id: query.id) == query)
    }

    @Test func persistsSelectDBProductIdentity() async throws {
        let repository = SQLiteConnectionProfileRepository(databaseURL: nil)
        let profile = ConnectionProfile(
            id: UUID(),
            name: "SelectDB Cloud",
            groupID: nil,
            databaseProduct: .selectDB,
            host: "example.selectdb.cloud",
            port: 9_030,
            username: "admin",
            defaultDatabase: "analytics",
            tlsMode: .verifyIdentity,
            storesCredential: false,
            createdAt: .now
        )

        try await repository.insert(profile)
        let stored = try #require(try await repository.fetch(id: profile.id))

        #expect(stored.databaseProduct == .selectDB)
        #expect(stored.databaseType == .doris)
    }

    @Test func movesProfilesAndGroupsWithStableOrdering() async throws {
        let repository = SQLiteConnectionProfileRepository(databaseURL: nil)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let development = ConnectionGroup(
            id: UUID(),
            name: "Development",
            sortIndex: 0,
            createdAt: createdAt
        )
        let production = ConnectionGroup(
            id: UUID(),
            name: "Production",
            sortIndex: 1,
            createdAt: createdAt
        )
        let local = ConnectionProfile(
            id: UUID(),
            name: "Local",
            groupID: development.id,
            host: "localhost",
            port: 3306,
            username: "root",
            defaultDatabase: nil,
            tlsMode: .disabled,
            storesCredential: false,
            sortIndex: 0,
            createdAt: createdAt
        )
        let primary = ConnectionProfile(
            id: UUID(),
            name: "Primary",
            groupID: production.id,
            host: "mysql.example.com",
            port: 3306,
            username: "developer",
            defaultDatabase: nil,
            tlsMode: .verifyIdentity,
            storesCredential: false,
            sortIndex: 0,
            createdAt: createdAt
        )
        let replica = ConnectionProfile(
            id: UUID(),
            name: "Replica",
            groupID: production.id,
            host: "replica.example.com",
            port: 3306,
            username: "developer",
            defaultDatabase: nil,
            tlsMode: .verifyIdentity,
            storesCredential: false,
            sortIndex: 1,
            createdAt: createdAt
        )
        try await repository.insert(development)
        try await repository.insert(production)
        try await repository.insert(local)
        try await repository.insert(primary)
        try await repository.insert(replica)

        try await repository.moveGroup(
            id: production.id,
            beforeGroupID: development.id
        )
        try await repository.moveProfile(
            id: local.id,
            toGroupID: production.id,
            beforeProfileID: replica.id
        )

        let snapshot = try await repository.fetchManagementSnapshot()
        #expect(snapshot.groups.map(\.id) == [production.id, development.id])
        #expect(
            snapshot.profiles
                .filter { $0.groupID == production.id }
                .map(\.id)
                == [primary.id, local.id, replica.id]
        )
        #expect(
            snapshot.profiles
                .filter { $0.groupID == production.id }
                .map(\.sortIndex)
                == [0, 1, 2]
        )
    }
}
