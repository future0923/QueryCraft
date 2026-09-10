enum WorkspaceDatabaseObjectsState: Equatable, Sendable {
    case notLoaded
    case queued
    case loading
    case loaded([WorkspaceDatabaseObject])
    case failed(String)
}
