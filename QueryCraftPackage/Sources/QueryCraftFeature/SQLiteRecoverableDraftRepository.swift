import Foundation
import GRDB

struct SQLiteRecoverableDraftRepository: RecoverableDraftRepository {
    private let database: SQLiteApplicationDatabase

    init(database: SQLiteApplicationDatabase = .shared) {
        self.database = database
    }

    init(databaseURL: URL?) {
        database = SQLiteApplicationDatabase(databaseURL: databaseURL)
    }

    func fetchAll(workspaceID: UUID) async throws -> [RecoverableDraft] {
        try await database.read { database in
            try RecoverableDraft
                .filter(Column("workspaceID") == workspaceID)
                .order(Column("createdAt"), Column("id"))
                .fetchAll(database)
        }
    }

    func fetchAll(
        connectionProfileID: ConnectionProfile.ID
    ) async throws -> [RecoverableDraft] {
        try await database.read { database in
            try RecoverableDraft
                .filter(
                    Column("connectionProfileID") == connectionProfileID
                )
                .order(Column("createdAt"), Column("id"))
                .fetchAll(database)
        }
    }

    func fetch(id: RecoverableDraft.ID) async throws -> RecoverableDraft? {
        try await database.read { database in
            try RecoverableDraft.fetchOne(database, key: id)
        }
    }

    func save(_ draft: RecoverableDraft) async throws {
        try await database.write { database in
            try draft.save(database)
        }
    }

    func delete(id: RecoverableDraft.ID) async throws {
        try await database.write { database in
            _ = try RecoverableDraft.deleteOne(database, key: id)
        }
    }

    func deleteAll(workspaceID: UUID) async throws {
        try await database.write { database in
            _ = try RecoverableDraft
                .filter(Column("workspaceID") == workspaceID)
                .deleteAll(database)
        }
    }
}
