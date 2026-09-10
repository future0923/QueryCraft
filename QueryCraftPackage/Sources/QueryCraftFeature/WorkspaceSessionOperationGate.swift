actor WorkspaceSessionOperationGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func runUncancelled<Value: Sendable>(
        _ operation: @Sendable () async -> Value
    ) async -> Value {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        guard isOccupied else {
            isOccupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isOccupied = false
            return
        }
        waiters.removeFirst().resume()
    }
}
