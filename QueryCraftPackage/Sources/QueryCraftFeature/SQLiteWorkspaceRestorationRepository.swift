import Foundation
import GRDB

struct SQLiteWorkspaceRestorationRepository:
    WorkspaceRestorationRepository
{
    private let database: SQLiteApplicationDatabase

    init(database: SQLiteApplicationDatabase = .shared) {
        self.database = database
    }

    init(databaseURL: URL?) {
        database = SQLiteApplicationDatabase(databaseURL: databaseURL)
    }

    func fetchAll() async throws -> [WorkspaceRestorationState] {
        try await database.read { database in
            try WorkspaceRestorationRecord
                .order(Column("createdAt"), Column("id"))
                .fetchAll(database)
                .map { try $0.state }
        }
    }

    func fetch(
        id: WorkspaceRestorationState.ID
    ) async throws -> WorkspaceRestorationState? {
        try await database.read { database in
            try WorkspaceRestorationRecord
                .fetchOne(database, key: id)?
                .state
        }
    }

    func save(_ state: WorkspaceRestorationState) async throws {
        try await database.write { database in
            let record = try WorkspaceRestorationRecord(state: state)
            try record.save(database)
        }
    }

    func delete(id: WorkspaceRestorationState.ID) async throws {
        try await database.write { database in
            _ = try WorkspaceRestorationRecord.deleteOne(database, key: id)
        }
    }
}

private struct WorkspaceRestorationRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "workspaceRestoration"

    let id: UUID
    let connectionProfileID: ConnectionProfile.ID
    let databaseContexts: Data
    let selectedDatabaseContextID: UUID
    let windowX: Double?
    let windowY: Double?
    let windowWidth: Double?
    let windowHeight: Double?
    let createdAt: Date
    let updatedAt: Date

    init(state: WorkspaceRestorationState) throws {
        id = state.id
        connectionProfileID = state.connectionProfileID
        databaseContexts = try JSONEncoder().encode(state.databaseContexts)
        selectedDatabaseContextID = state.selectedDatabaseContextID
        windowX = state.windowFrame?.x
        windowY = state.windowFrame?.y
        windowWidth = state.windowFrame?.width
        windowHeight = state.windowFrame?.height
        createdAt = state.createdAt
        updatedAt = state.updatedAt
    }

    var state: WorkspaceRestorationState {
        get throws {
            WorkspaceRestorationState(
                id: id,
                connectionProfileID: connectionProfileID,
                databaseContexts: try JSONDecoder().decode(
                    [WorkspaceDatabaseContextRestorationState].self,
                    from: databaseContexts
                ),
                selectedDatabaseContextID: selectedDatabaseContextID,
                windowFrame: windowFrame,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private var windowFrame: WorkspaceWindowFrame? {
        guard let windowX,
              let windowY,
              let windowWidth,
              let windowHeight
        else {
            return nil
        }
        return WorkspaceWindowFrame(
            x: windowX,
            y: windowY,
            width: windowWidth,
            height: windowHeight
        )
    }
}
