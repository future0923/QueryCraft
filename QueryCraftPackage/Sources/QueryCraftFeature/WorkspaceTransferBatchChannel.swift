import Foundation

/// One prefetched batch at most. A blocking C-library producer and asynchronous
/// consumer exchange values; only the dedicated transport queue blocks. Mutable
/// state and continuation ownership are exclusively protected by `condition`.
public final class WorkspaceTransferBatchChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private var batch: WorkspaceDatabaseDataBatch?
    private var receiver: CheckedContinuation<WorkspaceDatabaseDataBatch?, any Error>?
    private var finished = false
    private var failure: (any Error)?
    public init() {}

    public func send(_ value: WorkspaceDatabaseDataBatch) throws {
        condition.lock()
        while batch != nil && failure == nil && !finished { condition.wait() }
        if let failure { condition.unlock(); throw failure }
        guard !finished else { condition.unlock(); throw WorkspaceNativeBulkError.invalidStreamState }
        let receiver = self.receiver; self.receiver = nil
        if receiver == nil { batch = value }
        condition.unlock()
        receiver?.resume(returning: value)
    }

    public func next() async throws -> WorkspaceDatabaseDataBatch? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in receive(continuation) }
        } onCancel: { self.fail(CancellationError()) }
    }

    private func receive(_ continuation: CheckedContinuation<WorkspaceDatabaseDataBatch?, any Error>) {
        condition.lock()
        if let failure { condition.unlock(); continuation.resume(throwing: failure); return }
        if let batch {
            self.batch = nil; condition.broadcast(); condition.unlock(); continuation.resume(returning: batch); return
        }
        if finished { condition.unlock(); continuation.resume(returning: nil); return }
        guard receiver == nil else { condition.unlock(); continuation.resume(throwing: WorkspaceNativeBulkError.invalidStreamState); return }
        receiver = continuation; condition.unlock()
    }

    public func finish() {
        condition.lock(); finished = true
        let pending = receiver; receiver = nil; condition.broadcast(); condition.unlock()
        pending?.resume(returning: nil)
    }

    public func fail(_ error: any Error) {
        condition.lock()
        if failure == nil { failure = error }; batch = nil
        let pending = receiver; receiver = nil; condition.broadcast(); condition.unlock()
        pending?.resume(throwing: error)
    }
}
