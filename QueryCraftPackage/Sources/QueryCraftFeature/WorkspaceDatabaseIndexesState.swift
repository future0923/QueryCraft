enum WorkspaceDatabaseIndexesState: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded([WorkspaceDatabaseIndex])
    case failed(String)
}
