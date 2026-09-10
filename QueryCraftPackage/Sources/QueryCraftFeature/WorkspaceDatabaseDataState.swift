enum WorkspaceDatabaseDataState: Equatable, Sendable {
    case notLoaded
    case loading
    case fetching(WorkspaceDatabaseDataPage)
    case stopped(WorkspaceDatabaseDataPage?)
    case loaded(WorkspaceDatabaseDataPage)
    case failed(String)

    var page: WorkspaceDatabaseDataPage? {
        switch self {
        case let .fetching(page), let .loaded(page):
            page
        case let .stopped(page):
            page
        case .notLoaded, .loading, .failed:
            nil
        }
    }

    var isFetching: Bool {
        switch self {
        case .loading, .fetching:
            true
        case .notLoaded, .stopped, .loaded, .failed:
            false
        }
    }

    var isStopped: Bool {
        if case .stopped = self {
            true
        } else {
            false
        }
    }
}
