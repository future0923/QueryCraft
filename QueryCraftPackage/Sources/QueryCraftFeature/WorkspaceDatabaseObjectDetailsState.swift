enum WorkspaceDatabaseObjectDetailsState: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded(WorkspaceDatabaseObjectDetails)
    case failed(String)
}
