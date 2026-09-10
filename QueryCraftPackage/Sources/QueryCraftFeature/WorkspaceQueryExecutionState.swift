enum WorkspaceQueryExecutionState: Equatable, Sendable {
    case idle
    case running(WorkspaceQueryResultPage?)
    case stopped(WorkspaceQueryResultPage?)
    case completed(WorkspaceQueryResultPage)
    case failed(message: String, page: WorkspaceQueryResultPage?)
    case skipped(reason: String)

    var page: WorkspaceQueryResultPage? {
        switch self {
        case let .running(page), let .stopped(page), let .failed(_, page):
            page
        case let .completed(page):
            page
        case .idle, .skipped:
            nil
        }
    }

    var isRunning: Bool {
        if case .running = self {
            true
        } else {
            false
        }
    }
}
