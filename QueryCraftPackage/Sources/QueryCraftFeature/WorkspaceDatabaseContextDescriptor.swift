import Foundation

struct WorkspaceDatabaseContextDescriptor: Identifiable, Equatable, Sendable {
    let id: UUID
    let databaseName: String?
    let connectionState: WorkspaceConnectionState
}
