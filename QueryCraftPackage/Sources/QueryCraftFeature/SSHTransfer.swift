import Foundation
import CryptoKit
import Darwin

struct SSHTransferRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let connectionID: UUID
    let binding: String
    let upload: Bool
    let remotePath: String
    let localPath: String
    let stagingPath: String
    let createdAt: Date
    var cancellationVersion: Int? = nil
    func matches(_ profile: SSHConnection) -> Bool { connectionID == profile.id && binding == SSHTaskRecord.binding(profile) }
    var value: MCPJSONValue { .object(["transfer_id": .string(id.uuidString), "connection_id": .string(connectionID.uuidString),
        "direction": .string(upload ? "upload" : "download"), "remote_path": .string(remotePath), "local_path": .string(localPath),
        "staging_path": .string(stagingPath), "created_at_unix": .double(createdAt.timeIntervalSince1970), "outcome": "requires_inspection", "automatic_retry": false]) }
    func validate() throws {
        try SSHFileRequest.validateMutationPath(remotePath)
        guard localPath.hasPrefix("/"), !localPath.contains("\0"), localPath.utf8.count <= 4096,
              stagingPath.hasPrefix("/"), stagingPath != remotePath, stagingPath != localPath,
              stagingPath == Self.stagingPath(destination: upload ? remotePath : localPath, id: id) else {
            throw MCPFailure("Invalid transfer recovery record.", code: .policyUnavailable)
        }
    }
    static func stagingPath(destination: String, id: UUID) -> String {
        let end = destination.lastIndex(of: "/") ?? destination.startIndex
        return String(destination[...end]) + ".querycraft-" + id.uuidString + ".transfer"
    }
}

struct SSHTransferStore: Sendable {
    let directory: URL
    var url: URL { directory.appending(path: "ssh-transfers.json") }
    func operationLock(_ id: UUID) throws -> MCPComponentLock {
        try MCPComponentLock(directory: directory.appending(path: "SSHTransferOperations/" + id.uuidString))
    }
    func ownerLock(_ id: UUID) throws -> MCPComponentLock {
        try MCPComponentLock(directory: directory.appending(path: "SSHTransferOperations/" + id.uuidString), filename: ".transfer.lock")
    }
    func load() throws -> [SSHTransferRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let records = try JSONDecoder().decode([SSHTransferRecord].self, from: Data(contentsOf: url))
            guard records.count <= 512, Set(records.map(\.id)).count == records.count else { throw MCPFailure("Invalid records.") }
            try records.forEach { try $0.validate() }; return records
        } catch { throw MCPFailure("Cannot read ssh-transfers.json. Repair the recovery records.", code: .policyUnavailable) }
    }
    func insert(_ record: SSHTransferRecord) throws {
        try record.validate()
        var retired: Set<UUID> = []
        try mutate { records in
            // Only terminal successful results are eligible for automatic
            // retention cleanup. Failed/unknown records may own staging data.
            let completed = try records.compactMap { record -> SSHTransferRecord? in
                try loadStatus(record.id)?.state == .completed && !isActive(record.id) ? record : nil
            }.sorted { $0.createdAt < $1.createdAt }
            let expired = completed.filter { $0.createdAt < Date().addingTimeInterval(-7 * 86400) }
            let excess = max(0, records.count - expired.count - 511)
            retired = Set((expired + completed.filter { candidate in !expired.contains(where: { $0.id == candidate.id }) }.prefix(excess)).map(\.id))
            records.removeAll { retired.contains($0.id) }
            guard records.count < 512, !records.contains(where: { $0.id == record.id }) else { throw MCPFailure("Transfer recovery capacity reached. Inspect and clean up records first.", code: .capacity) }
            records.append(record)
        }
        for id in retired { removeStatus(id) }
    }
    func isActive(_ id: UUID, transferOwner: Bool = false) throws -> Bool {
        let path = directory.appending(path: "SSHTransferOperations/" + id.uuidString + (transferOwner ? "/.transfer.lock" : "/.component.lock"))
        let fd = Darwin.open(path.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw MCPFailure("Cannot inspect the transfer operation lock.")
        }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        guard errno == EWOULDBLOCK else { throw MCPFailure("Cannot inspect the transfer operation lock.") }
        return true
    }
    func cancellationURL(_ id: UUID) -> URL {
        directory.appending(path: "SSHTransferOperations/" + id.uuidString + "/cancel")
    }
    func cancellationRequested(_ id: UUID) -> Bool {
        var info = stat()
        return Darwin.lstat(cancellationURL(id).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
    func requestCancellation(_ record: SSHTransferRecord) throws {
        let lock = try MCPComponentLock(directory: directory.appending(path: "SSHTransferRegistry"))
        defer { withExtendedLifetime(lock) {} }
        guard record.cancellationVersion == 1, try load().contains(where: { $0.id == record.id && $0.binding == record.binding }),
              try isActive(record.id, transferOwner: true) else { throw MCPFailure("Transfer is no longer active or its owner does not support cancellation. Inspect its outcome.") }
        let fd = Darwin.open(cancellationURL(record.id).path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        if fd >= 0 { Darwin.close(fd) }
        else if errno != EEXIST || !cancellationRequested(record.id) { throw MCPFailure("Cannot request transfer cancellation.") }
    }
    func remove(_ id: UUID) throws {
        try mutate {
            $0.removeAll { $0.id == id }
            if cancellationRequested(id) { _ = Darwin.unlink(cancellationURL(id).path) }
        }
        removeStatus(id)
    }
    private func mutate(_ update: (inout [SSHTransferRecord]) throws -> Void) throws {
        let lock = try MCPComponentLock(directory: directory.appending(path: "SSHTransferRegistry"))
        defer { withExtendedLifetime(lock) {} }
        var records = try load(); try update(&records)
        let temp = directory.appending(path: ".ssh-transfers-" + UUID().uuidString)
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw MCPFailure("Cannot save transfer recovery records.", code: .policyUnavailable) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: JSONEncoder().encode(records)); try handle.synchronize()
        guard Darwin.rename(temp.path, url.path) == 0 else { throw MCPFailure("Cannot save transfer recovery records.", code: .policyUnavailable) }
    }
}
