import Foundation
import Darwin

struct MCPExportRecord: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, running, finalizing, succeeded, failed, cancelled, interrupted
        var active: Bool { [.queued, .running, .finalizing].contains(self) }
    }
    let id: UUID
    let accessToken: String
    let request: MCPExportRequest
    let profileDigest: String
    let createdAt: Date
    var expiresAt: Date
    var status: Status = .queued
    var counts: [Int]
    var queryIndex: Int?
    var cancelRequested = false
    var completedAt: Date?
    var fileBytes: Int?
    var sha256: String?
    var textFallbackCells = 0
    var errorCode: String?
    var errorMessage: String?

    func value(store: MCPExportStore, includeToken: Bool = false, includeArtifact: Bool = true) -> MCPJSONValue {
        func date(_ d: Date) -> MCPJSONValue { .string(ISO8601DateFormatter().string(from: d)) }
        var result: [String: MCPJSONValue] = [
            "job_id": .string(id.uuidString), "status": .string(status.rawValue),
            "created_at": date(createdAt), "completed_at": completedAt.map(date) ?? .null,
            "expires_at": date(expiresAt), "cancel_requested": .bool(cancelRequested),
            "current_query": queryIndex.map(MCPJSONValue.int) ?? .null,
            "total_rows": .int(counts.reduce(0, +)), "complete": .bool(status == .succeeded),
            "consistency": .string(request.consistency.rawValue), "timezone": .string(request.timezone),
            "delivery": "local_filesystem", "requires_same_filesystem": true,
            "automatic_retry": false,
            "warnings": .array((textFallbackCells > 0 ? [MCPJSONValue.string("\(textFallbackCells) typed cells were preserved as text to avoid precision/date loss.")] : []) + (request.format == .csv ? [MCPJSONValue.string("CSV uses reversible NULL/backslash escaping and TAB prefixes for spreadsheet-risk fields. Import columns as text; see manifest.json.")] : [])),
            "queries": .array(request.queries.enumerated().map { i, q in .object(["name": .string(q.name), "rows_written": .int(counts[i]), "expected_rows": q.expectedRows.map(MCPJSONValue.int) ?? .null]) }),
            "effective_limits": .object(["max_rows": .int(request.limits.rows), "max_file_bytes": .int(request.limits.fileBytes), "max_raw_bytes": .int(request.limits.rawBytes), "timeout_seconds": .int(request.limits.timeoutSeconds)])
        ]
        if includeToken { result["access_token"] = .string(accessToken) }
        if status == .succeeded, includeArtifact {
            result["artifact"] = .object(["filename": .string(request.filename), "local_path": .string(store.artifact(self).path),
                "manifest_path": .string(store.job(id).appending(path: "manifest.json").path),
                "size_bytes": fileBytes.map(MCPJSONValue.int) ?? .null, "sha256": sha256.map(MCPJSONValue.string) ?? .null,
                "media_type": .string(request.fileExtension == "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : request.fileExtension == "zip" ? "application/zip" : "text/csv; charset=utf-8")])
        }
        if let errorCode { result["error"] = .object(["code": .string(errorCode), "message": .string(errorMessage ?? "Export failed; no artifact is available."), "retryable": .bool(["OPERATION_TIMEOUT", "CONNECTION_FAILED", "INTERRUPTED"].contains(errorCode))]) }
        return .object(result)
    }
}

/// Kernel locks release on process death. Immutable descriptors are never explicitly closed
/// while shared; ARC owns their lifetime, and flock protects processes as well as actors.
final class MCPExportLease: Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
    static func acquire(_ url: URL, wait: Bool = false) throws -> MCPExportLease? {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MCPFailure("Cannot open export lock.") }
        if flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
            let failure = errno; Darwin.close(fd)
            if failure == EWOULDBLOCK { return nil }
            throw MCPFailure("Cannot lock export storage.")
        }
        return MCPExportLease(fd)
    }
}

struct MCPExportStore: Sendable {
    let root: URL
    init(directory: URL) { root = directory.appending(path: "MCP/Exports", directoryHint: .isDirectory) }
    func job(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func artifact(_ record: MCPExportRecord) -> URL { job(record.id).appending(path: record.request.filename) }
    func temporary(_ id: UUID) -> URL { job(id).appending(path: "artifact.partial") }
    func owner(_ id: UUID) throws -> MCPExportLease? { try MCPExportLease.acquire(job(id).appending(path: "owner.lock")) }

    func prepare() throws {
        try Self.directory(root.deletingLastPathComponent())
        try Self.directory(root)
    }
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MCPFailure("Export directory must not be a symlink.") }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw MCPFailure("Cannot protect export directory.") }
    }
    func locked<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let lease = try MCPExportLease.acquire(root.appending(path: "store.lock"), wait: true)
        defer { withExtendedLifetime(lease) {} }
        return try body()
    }
    func read(_ id: UUID) throws -> MCPExportRecord {
        let directory = job(id)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MCPFailure("Invalid job directory.") }
        let path = directory.appending(path: "record.json")
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_097_152 else { throw MCPFailure("Invalid export record.") }
        return try JSONDecoder().decode(MCPExportRecord.self, from: Data(contentsOf: path))
    }
    func write(_ record: MCPExportRecord) throws {
        let destination = job(record.id).appending(path: "record.json")
        let data = try JSONEncoder().encode(record)
        guard data.count <= 2_097_152 else { throw MCPFailure("Export record exceeds its storage budget.", code: .resultTooLarge) }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func update(_ id: UUID, _ body: (inout MCPExportRecord) throws -> Void) throws -> MCPExportRecord {
        try locked { var record = try read(id); try body(&record); try write(record); return record }
    }
    func records() throws -> [MCPExportRecord] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try? read(id)
        }
    }
    /// Called under the store lock. An active owner lease prevents false crash recovery.
    func reconcile(_ input: MCPExportRecord) throws -> MCPExportRecord {
        var record = input
        if record.status.active, let lease = try owner(record.id) {
            defer { withExtendedLifetime(lease) {} }
            record.status = .interrupted; record.completedAt = Date()
            record.errorCode = "INTERRUPTED"; record.errorMessage = "Export process stopped. Retry the whole export with a new idempotency_key."
            try? FileManager.default.removeItem(at: temporary(record.id))
            try? FileManager.default.removeItem(at: artifact(record))
            try write(record)
        }
        return record
    }
    func cleanup() throws {
        try locked {
            for input in try records() {
                let record = try reconcile(input)
                if !record.status.active, record.expiresAt < Date(), let lease = try owner(record.id) {
                    defer { withExtendedLifetime(lease) {} }
                    try FileManager.default.removeItem(at: job(record.id))
                }
            }
        }
    }
}
