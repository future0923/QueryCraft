enum WorkspaceDatabaseDataCountState: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded(Int)
    case failed
}
