import Foundation
import GRDB

struct SQLiteSavedQueryRepository: SavedQueryRepository {
    private let database: SQLiteApplicationDatabase

    init(database: SQLiteApplicationDatabase = .shared) {
        self.database = database
    }

    init(databaseURL: URL?) {
        database = SQLiteApplicationDatabase(databaseURL: databaseURL)
    }

    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [SavedQuery] {
        try await database.read { database in
            try SavedQuery
                .filter(
                    Column("connectionProfileID") == connectionProfileID
                )
                .order(
                    Column("defaultDatabase"),
                    Column("name").collating(.nocase),
                    Column("createdAt"),
                    Column("id")
                )
                .fetchAll(database)
        }
    }

    func fetch(id: SavedQuery.ID) async throws -> SavedQuery? {
        try await database.read { database in
            try SavedQuery.fetchOne(database, key: id)
        }
    }

    func insert(_ query: SavedQuery) async throws {
        do {
            try await database.write { database in
                try query.insert(database)
            }
        } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
        {
            throw SavedQueryRepositoryError.nameAlreadyExists
        }
    }

    func update(_ query: SavedQuery) async throws {
        do {
            try await database.write { database in
                try query.update(database)
            }
        } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
        {
            throw SavedQueryRepositoryError.nameAlreadyExists
        }
    }

    func delete(id: SavedQuery.ID) async throws {
        try await database.write { database in
            _ = try SavedQuery.deleteOne(database, key: id)
        }
    }
}
