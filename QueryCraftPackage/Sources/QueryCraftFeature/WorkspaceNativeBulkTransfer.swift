import Foundation

/// An additive capability: older API 5 drivers keep using their existing INSERT path.
/// New driver bundles referencing this capability require app version 0.1.10 or newer.
public protocol WorkspaceNativeBulkTransferSession: WorkspaceSession {
    func nativeBulkTransferFormat() async throws -> WorkspaceNativeBulkFormat?
    func executeNativeBulkTransfer(sql: String, token: String,
                                   stream: WorkspaceNativeBulkStream) async throws -> Int
}

public enum WorkspaceNativeBulkFormat: Sendable {
    case postgresqlCopyText, mysqlLocalTSV
}

/// PostgreSQL can forward COPY text unchanged when both column layouts match.
public protocol WorkspaceNativeCopySourceSession: WorkspaceSession {
    func executeNativeCopyOut(sql: String, stream: WorkspaceNativeBulkStream,
                              onProgress: @escaping @Sendable (Int) async -> Void) async throws -> Int
}

/// Single producer, single synchronous C-library consumer. No files are opened.
/// Every mutable property is protected by `condition`. The async sender is resumed
/// only after the consumer has consumed its entire chunk, providing backpressure
/// without blocking a Swift cooperative-executor thread. Only the C-library queue
/// may call the blocking read method. Failure wakes both ends, including on cancel.
public final class WorkspaceNativeBulkStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunk: Data?
    private var offset = 0
    private var sender: CheckedContinuation<Void, any Error>?
    private var finished = false
    private var failure: (any Error)?

    public init() {}

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(data, continuation: continuation)
            }
        } onCancel: { self.fail(CancellationError()) }
    }

    private func install(_ data: Data, continuation: CheckedContinuation<Void, any Error>) {
        condition.lock()
        if let failure {
            condition.unlock(); continuation.resume(throwing: failure); return
        }
        guard !finished, chunk == nil, sender == nil else {
            condition.unlock()
            continuation.resume(throwing: WorkspaceNativeBulkError.invalidStreamState)
            return
        }
        chunk = data; offset = 0; sender = continuation
        condition.broadcast(); condition.unlock()
    }

    /// Blocks a dedicated C transport queue, never a Swift task executor.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        condition.lock()
        while chunk == nil && failure == nil && !finished { condition.wait() }
        if let failure { condition.unlock(); throw failure }
        guard let chunk else { condition.unlock(); return 0 }
        let count = min(buffer.count, chunk.count - offset)
        chunk.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: offset..<(offset + count))
        offset += count
        var completed: CheckedContinuation<Void, any Error>?
        if offset == chunk.count {
            self.chunk = nil; offset = 0; completed = sender; sender = nil
        }
        condition.unlock()
        completed?.resume()
        return count
    }

    public func finish() {
        condition.lock(); finished = true; condition.broadcast(); condition.unlock()
    }

    public func fail(_ error: any Error) {
        condition.lock()
        if failure == nil { failure = error }
        let pending = sender; sender = nil; chunk = nil; offset = 0
        condition.broadcast(); condition.unlock()
        pending?.resume(throwing: error)
    }

    public func checkFailure() throws {
        condition.lock(); let error = failure; condition.unlock()
        if let error { throw error }
    }
}

public enum WorkspaceNativeBulkError: LocalizedError {
    case invalidStreamState
    case invalidLocalRequest
    case serverWarning(String)
    case invalidTextEncoding

    public var errorDescription: String? {
        switch self {
        case .invalidStreamState: "Invalid native transfer stream state."
        case .invalidLocalRequest: "The server requested an unexpected LOCAL INFILE resource."
        case .serverWarning(let detail): "Native load reported a warning; the transfer must roll back: \(detail)"
        case .invalidTextEncoding: "The source returned invalid UTF-8 text. Use an explicit binary conversion."
        }
    }
}
