import Foundation

struct WorkspaceRestorationState: Equatable, Identifiable, Sendable {
    let id: UUID
    let connectionProfileID: ConnectionProfile.ID
    let databaseContexts: [WorkspaceDatabaseContextRestorationState]
    let selectedDatabaseContextID: UUID
    let windowFrame: WorkspaceWindowFrame?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID,
        connectionProfileID: ConnectionProfile.ID,
        databaseContexts: [WorkspaceDatabaseContextRestorationState],
        selectedDatabaseContextID: UUID,
        windowFrame: WorkspaceWindowFrame?,
        createdAt: Date,
        updatedAt: Date
    ) {
        precondition(!databaseContexts.isEmpty)
        self.id = id
        self.connectionProfileID = connectionProfileID
        self.databaseContexts = databaseContexts
        self.selectedDatabaseContextID = selectedDatabaseContextID
        self.windowFrame = windowFrame
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var selectedDatabaseContext: WorkspaceDatabaseContextRestorationState {
        databaseContexts.first { $0.id == selectedDatabaseContextID }
            ?? databaseContexts[0]
    }
}
