struct WorkspaceDatabase: Equatable, Identifiable, Sendable {
    let name: String
    var objectsState = WorkspaceDatabaseObjectsState.notLoaded

    var id: String { name }
}
