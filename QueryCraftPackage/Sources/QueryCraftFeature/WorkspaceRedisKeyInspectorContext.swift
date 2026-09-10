struct WorkspaceRedisKeyInspectorContext: Equatable {
    enum State: Equatable, Sendable {
        case loading
        case loaded(RedisKeyDetails)
        case failed(String)
    }

    let reference: RedisKeyReference
    let state: State
    let retry: @MainActor () -> Void

    init(
        reference: RedisKeyReference,
        details: RedisKeyDetails?,
        errorMessage: String?,
        retry: @escaping @MainActor () -> Void
    ) {
        self.reference = reference
        if let details {
            state = .loaded(details)
        } else if let errorMessage {
            state = .failed(errorMessage)
        } else {
            state = .loading
        }
        self.retry = retry
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reference == rhs.reference && lhs.state == rhs.state
    }
}
