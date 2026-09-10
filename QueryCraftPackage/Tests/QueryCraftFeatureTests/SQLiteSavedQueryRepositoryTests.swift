import Foundation
import Testing
@testable import QueryCraftFeature

struct SQLiteSavedQueryRepositoryTests {
    @Test func storesUpdatesAndDeletesQueriesWithinOneProfile() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let repository = SQLiteSavedQueryRepository(database: database)
        let profile = makeProfile(name: "Local")
        let otherProfile = makeProfile(name: "Staging")
        try await profileRepository.insert(profile)
        try await profileRepository.insert(otherProfile)

        let createdAt = Date(timeIntervalSince1970: 1_000)
        let general = makeQuery(
            profileID: profile.id,
            defaultDatabase: nil,
            name: "Server Status",
            sql: "SHOW STATUS;",
            createdAt: createdAt
        )
        let databaseQuery = makeQuery(
            profileID: profile.id,
            defaultDatabase: "querycraft",
            name: "Recent Users",
            sql: "SELECT * FROM users;",
            createdAt: createdAt.addingTimeInterval(1)
        )
        let otherProfileQuery = makeQuery(
            profileID: otherProfile.id,
            defaultDatabase: nil,
            name: "Server Status",
            sql: "SHOW STATUS;",
            createdAt: createdAt
        )

        try await repository.insert(databaseQuery)
        try await repository.insert(otherProfileQuery)
        try await repository.insert(general)

        #expect(
            try await repository.fetchAll(
                connectionProfileID: profile.id
            ) == [general, databaseQuery]
        )
        #expect(try await repository.fetch(id: general.id) == general)

        let updated = SavedQuery(
            id: databaseQuery.id,
            connectionProfileID: profile.id,
            defaultDatabase: "analytics",
            name: "Active Users",
            sql: "SELECT * FROM users WHERE active = TRUE;",
            createdAt: databaseQuery.createdAt,
            updatedAt: createdAt.addingTimeInterval(10)
        )
        try await repository.update(updated)

        #expect(try await repository.fetch(id: updated.id) == updated)

        try await repository.delete(id: general.id)

        #expect(try await repository.fetch(id: general.id) == nil)
        #expect(
            try await repository.fetchAll(
                connectionProfileID: otherProfile.id
            ) == [otherProfileQuery]
        )
    }

    @Test func enforcesNamesWithinGeneralAndDatabaseScopes() async throws {
        let database = SQLiteApplicationDatabase(databaseURL: nil)
        let profileRepository = SQLiteConnectionProfileRepository(
            database: database
        )
        let repository = SQLiteSavedQueryRepository(database: database)
        let profile = makeProfile(name: "Local")
        try await profileRepository.insert(profile)

        let general = makeQuery(
            profileID: profile.id,
            defaultDatabase: nil,
            name: "Health Check"
        )
        try await repository.insert(general)

        await expectInsertFailure(
            makeQuery(
                profileID: profile.id,
                defaultDatabase: nil,
                name: general.name
            ),
            repository: repository
        )

        let primaryDatabase = makeQuery(
            profileID: profile.id,
            defaultDatabase: "querycraft",
            name: general.name
        )
        try await repository.insert(primaryDatabase)

        await expectInsertFailure(
            makeQuery(
                profileID: profile.id,
                defaultDatabase: primaryDatabase.defaultDatabase,
                name: primaryDatabase.name
            ),
            repository: repository
        )

        let otherDatabase = makeQuery(
            profileID: profile.id,
            defaultDatabase: "analytics",
            name: general.name
        )
        try await repository.insert(otherDatabase)

        #expect(
            try await repository.fetchAll(
                connectionProfileID: profile.id
            ).count == 3
        )
    }

    private func expectInsertFailure(
        _ query: SavedQuery,
        repository: SQLiteSavedQueryRepository
    ) async {
        do {
            try await repository.insert(query)
            Issue.record("Expected the duplicate Saved Query name to fail.")
        } catch {
            #expect(
                error as? SavedQueryRepositoryError
                    == .nameAlreadyExists
            )
        }
    }

    private func makeProfile(name: String) -> ConnectionProfile {
        ConnectionProfile(
            id: UUID(),
            name: name,
            groupID: nil,
            host: "localhost",
            port: 3306,
            username: "root",
            defaultDatabase: nil,
            tlsMode: .verifyIdentity,
            storesCredential: false,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeQuery(
        profileID: ConnectionProfile.ID,
        defaultDatabase: String? = nil,
        name: String,
        sql: String = "SELECT 1;",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> SavedQuery {
        SavedQuery(
            id: UUID(),
            connectionProfileID: profileID,
            defaultDatabase: defaultDatabase,
            name: name,
            sql: sql,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
