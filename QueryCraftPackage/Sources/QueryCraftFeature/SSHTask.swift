import Foundation
import CryptoKit
import Darwin

struct SSHTaskRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let connectionID: UUID
    let binding: String
    let createdAt: Date
    static func binding(_ profile: SSHConnection) -> String {
        let identity = [profile.host, String(profile.port), profile.username, profile.hostFingerprint] + (profile.jumpConnectionID.map { [$0.uuidString] } ?? [])
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func matches(_ profile: SSHConnection) -> Bool { connectionID == profile.id && binding == Self.binding(profile) }
    var value: MCPJSONValue {
        .object(["task_id": .string(id.uuidString), "connection_id": .string(connectionID.uuidString),
            "created_at_unix": .double(createdAt.timeIntervalSince1970), "state": "not_polled", "automatic_retry": false])
    }
}

struct SSHTaskStore: Sendable {
    let directory: URL
    var url: URL { directory.appending(path: "ssh-tasks.json") }
    func load() throws -> [SSHTaskRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let records = try JSONDecoder().decode([SSHTaskRecord].self, from: Data(contentsOf: url))
            guard records.count <= 512, Set(records.map(\.id)).count == records.count else { throw MCPFailure("Invalid task records.") }
            return records
        } catch { throw MCPFailure("SSH task records cannot be read. Repair ssh-tasks.json.", code: .policyUnavailable) }
    }
    func insert(_ record: SSHTaskRecord) throws {
        try mutate { records in
            guard records.count < 512, !records.contains(where: { $0.id == record.id }) else { throw MCPFailure("SSH task record capacity reached (512). Clean up finished tasks.", code: .capacity) }
            records.append(record)
        }
    }
    func remove(_ id: UUID) throws { try mutate { $0.removeAll { $0.id == id } } }
    private func mutate(_ update: (inout [SSHTaskRecord]) throws -> Void) throws {
        let lock = try MCPComponentLock(directory: directory.appending(path: "SSHTaskOperations"))
        defer { withExtendedLifetime(lock) {} }
        var records = try load(); try update(&records)
        let temporary = directory.appending(path: ".ssh-tasks-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw MCPFailure("Cannot save SSH task records.", code: .policyUnavailable) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: JSONEncoder().encode(records)); try file.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw MCPFailure("Cannot save SSH task records.", code: .policyUnavailable) }
    }
}

enum SSHTaskCommand {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func make(action: String, id: UUID, payload: [String: MCPJSONValue]) throws -> String {
        guard let resource = Bundle.module.url(forResource: "ssh_task", withExtension: "sh"),
              let source = try? String(contentsOf: resource, encoding: .utf8) else { throw MCPFailure("SSH task shell resource is unavailable.", code: .unsupported) }
        func encoded(_ name: String) -> String { Data((payload[name]?.stringValue ?? "").utf8).base64EncodedString() }
        let fields = [action, id.uuidString, action == "start" ? Data(source.utf8).base64EncodedString() : "",
            encoded("command"), encoded("working_directory"), String(payload.integer("task_timeout_seconds", default: 3600)),
            String(payload.integer("max_log_bytes", default: 4_194_304)), payload.string("stream") ?? "stdout",
            String(payload.integer("offset", default: 0)), String(payload.integer("max_bytes", default: 16_384))]
        return "/bin/bash -c " + shellQuote(source) + " -- " + fields.map(shellQuote).joined(separator: " ")
    }
}
