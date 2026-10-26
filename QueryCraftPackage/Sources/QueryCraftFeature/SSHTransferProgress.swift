import Foundation
import Darwin

struct SSHTransferProgress: Sendable {
    enum Phase: UInt32, Sendable { case transferring = 1, verifying, publishing }
    let phase: Phase
    let transferred: UInt64
    let total: UInt64?
}

struct SSHTransferStatus: Codable, Sendable {
    enum State: String, Codable, Sendable { case running, completed, failed, cancelled, unknown }
    var state: State = .running
    var phase = "preparing"
    var bytes: UInt64?
    var total: UInt64?
    var averageBytesPerSecond: Double?
    var updatedAt = Date()
    var progressAvailable: Bool
    var result: MCPJSONValue?
    var errorCode: MCPFailureCode?
    var sshDiagnostic: SSHDiagnostic? = nil
    var terminal: Bool { [.completed, .failed, .cancelled].contains(state) }
    var value: [String: MCPJSONValue] {
        ["state": .string(state.rawValue), "phase": .string(phase), "progress_available": .bool(progressAvailable),
         "bytes_transferred": bytes.map { .int(Int(clamping: $0)) } ?? .null,
         "total_bytes": total.map { .int(Int(clamping: $0)) } ?? .null,
         "average_bytes_per_second": averageBytesPerSecond.map(MCPJSONValue.double) ?? .null,
         "updated_at_unix": .double(updatedAt.timeIntervalSince1970), "result": result ?? .null,
         "error_code": errorCode.map { .string($0.rawValue) } ?? .null,
         "ssh_diagnostic": sshDiagnostic?.value ?? .null,
         "destination_outcome": state == .completed ? "published_at_completion; current contents not reverified" : "unknown",
         "automatic_retry": false]
    }
}

extension SSHTransferStore {
    private func statusURL(_ id: UUID) -> URL { directory.appending(path: "SSHTransferOperations/" + id.uuidString + "/status.json") }
    func loadStatus(_ id: UUID) throws -> SSHTransferStatus? {
        let fd = Darwin.open(statusURL(id).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw MCPFailure("Cannot read transfer status.", code: .policyUnavailable)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, (1...16_384).contains(info.st_size) else {
            throw MCPFailure("Invalid transfer status file.", code: .policyUnavailable)
        }
        do {
            let data = try handle.read(upToCount: 16_385) ?? Data()
            let status = try JSONDecoder().decode(SSHTransferStatus.self, from: data)
            guard data.count <= 16_384, status.bytes.map({ $0 <= 1_073_741_824 }) ?? true,
                  status.total.map({ $0 <= 1_073_741_824 }) ?? true,
                  ["preparing", "transferring", "verifying", "publishing", "finished"].contains(status.phase),
                  status.sshDiagnostic?.isValid ?? true,
                  status.state != .completed || status.result?.objectValue?["status"] == "completed" else { throw MCPFailure("Invalid status.") }
            return status
        } catch { throw MCPFailure("Cannot decode transfer status. Inspect the transfer outcome.", code: .policyUnavailable) }
    }
    func status(_ record: SSHTransferRecord) throws -> SSHTransferStatus {
        var status = try loadStatus(record.id) ?? SSHTransferStatus(updatedAt: record.createdAt, progressAvailable: false)
        if !status.terminal, try !isActive(record.id, transferOwner: true) {
            status.state = .unknown
            status.averageBytesPerSecond = nil
        }
        return status
    }
    func statusValue(_ record: SSHTransferRecord) throws -> MCPJSONValue {
        var value = record.value.objectValue ?? [:]
        value.removeValue(forKey: "outcome")
        value.merge(try status(record).value) { _, new in new }
        value["cancellation_requested"] = .bool(cancellationRequested(record.id))
        return .object(value)
    }
    func saveStatus(_ status: SSHTransferStatus, id: UUID) throws {
        let target = statusURL(id)
        let temporary = target.deletingLastPathComponent().appending(path: ".status-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MCPFailure("Cannot persist transfer status.", code: .policyUnavailable) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); _ = Darwin.unlink(temporary.path) }
        let data = try JSONEncoder().encode(status)
        guard data.count <= 16_384 else { throw MCPFailure("Transfer status exceeds its storage limit.", code: .policyUnavailable) }
        try handle.write(contentsOf: data)
        if status.terminal { try handle.synchronize() }
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw MCPFailure("Cannot publish transfer status.", code: .policyUnavailable) }
        if status.terminal {
            let parent = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
            if parent >= 0 { defer { Darwin.close(parent) }; _ = fsync(parent) }
        }
    }
    func removeStatus(_ id: UUID) { _ = Darwin.unlink(statusURL(id).path) }
}

/// Callback/monitor access is serialized by the lock. Only immutable store/ID
/// escape it. C callbacks finish before the owner publishes its terminal result.
final class SSHTransferRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let store: SSHTransferStore
    private let id: UUID
    private let started = ContinuousClock.now
    private var lastSaved = ContinuousClock.now
    private var snapshot: SSHTransferStatus
    init(store: SSHTransferStore, id: UUID, progressAvailable: Bool) throws {
        self.store = store; self.id = id
        snapshot = SSHTransferStatus(progressAvailable: progressAvailable)
        try store.saveStatus(snapshot, id: id)
    }
    func receive(_ progress: SSHTransferProgress) {
        lock.withLock {
            guard !snapshot.terminal else { return }
            let phase = String(describing: progress.phase)
            let changed = snapshot.phase != phase
            snapshot.phase = phase
            snapshot.bytes = max(snapshot.bytes ?? 0, progress.transferred)
            snapshot.total = progress.total.flatMap { $0 >= (snapshot.bytes ?? 0) ? $0 : nil }
            if changed || lastSaved.duration(to: .now) >= .milliseconds(250) { publish() }
        }
    }
    func heartbeat() { lock.withLock { if !snapshot.terminal { publish() } } }
    private func publish() {
        snapshot.updatedAt = Date()
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        snapshot.averageBytesPerSecond = snapshot.bytes.map { Double($0) / max(0.001, seconds) }
        try? store.saveStatus(snapshot, id: id)
        lastSaved = .now
    }
    func finish(result: MCPJSONValue) throws {
        try lock.withLock {
            snapshot.state = .completed; snapshot.phase = "finished"; snapshot.result = result
            if case .int(let bytes)? = result.objectValue?["bytes_transferred"] {
                snapshot.bytes = UInt64(bytes); snapshot.total = UInt64(bytes)
            }
            snapshot.updatedAt = Date(); snapshot.averageBytesPerSecond = nil
            try store.saveStatus(snapshot, id: id)
        }
    }
    func fail(_ failure: MCPFailure) {
        lock.withLock {
            // A completed in-memory snapshot whose final save failed must not
            // be replaced by a false failed/preserved-destination assertion.
            guard snapshot.state != .completed else { return }
            snapshot.state = failure.code == .cancelled ? .cancelled : .failed
            snapshot.errorCode = failure.code; snapshot.updatedAt = Date(); snapshot.averageBytesPerSecond = nil
            snapshot.sshDiagnostic = failure.details?.objectValue?["ssh"].flatMap(SSHDiagnostic.init(value:))
            try? store.saveStatus(snapshot, id: id)
        }
    }
}
