import Foundation
import Darwin

struct ShellScript: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var script: String
    var revision: Int
    let createdAt: Date
    var updatedAt: Date

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              description.utf8.count <= 2048, !description.contains("\0"),
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              script.utf8.count <= 65_536, !script.contains("\0"), revision > 0,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else {
            throw MCPFailure("Invalid Shell script. Name: 1–256 UTF-8 bytes; description: up to 2048; script: 1–65536, without NUL.")
        }
    }
    var receipt: MCPJSONValue {
        .object(["script_id": .string(id.uuidString), "revision": .int(revision), "saved": true])
    }
    var value: MCPJSONValue {
        .object(["script_id": .string(id.uuidString), "name": .string(name), "description": .string(description),
                 "revision": .int(revision), "created_at": .string(createdAt.ISO8601Format()),
                 "updated_at": .string(updatedAt.ISO8601Format())])
    }
}

/// Local scripts are independent from connections. Mutations take one cross-process
/// lock and replace one private file atomically; scripts are never executed here.
struct ShellScriptStore: Sendable {
    let directory: URL
    static let maximumBytes = 8 * 1024 * 1024
    var url: URL { directory.appending(path: "shell-scripts.json") }
    private struct Archive: Codable { let version: Int; var scripts: [ShellScript] }

    func load() throws -> [ShellScript] {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw MCPFailure("Cannot read the private Shell script library.", code: .policyUnavailable)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0, (1...Int64(Self.maximumBytes)).contains(info.st_size) else {
            throw MCPFailure("Shell script library must be a private regular file within its size limit.", code: .policyUnavailable)
        }
        do {
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw MCPFailure("Shell library exceeds its size limit.") }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.scripts.count <= 128,
                  Set(archive.scripts.map(\.id)).count == archive.scripts.count else { throw MCPFailure("Invalid Shell library format.") }
            for script in archive.scripts { try script.validate() }
            return archive.scripts
        } catch {
            throw MCPFailure("Shell script library cannot be decoded. Repair shell-scripts.json; existing data was preserved.", code: .policyUnavailable)
        }
    }
    func create(name: String, description: String, script: String) throws -> ShellScript {
        let record = ShellScript(id: UUID(), name: name, description: description, script: script, revision: 1, createdAt: Date(), updatedAt: Date())
        try record.validate()
        try mutate { records in
            guard records.count < 128 else { throw MCPFailure("Shell script capacity reached (128).", code: .capacity) }
            records.append(record)
        }
        return record
    }
    func update(id: UUID, revision: Int, name: String?, description: String?, script: String?) throws -> ShellScript {
        var result: ShellScript?
        try mutate { records in
            let index = try Self.index(id, revision: revision, records: records)
            guard name != nil || description != nil || script != nil else { throw MCPFailure("Supply at least one field to update.") }
            guard records[index].revision < Int.max else { throw MCPFailure("Shell script revision limit reached.", code: .capacity) }
            if let name { records[index].name = name }
            if let description { records[index].description = description }
            if let script { records[index].script = script }
            records[index].revision += 1; records[index].updatedAt = Date()
            try records[index].validate(); result = records[index]
        }
        guard let result else { throw MCPFailure("Shell script update did not complete.") }
        return result
    }
    func remove(id: UUID, revision: Int) throws {
        try mutate { records in records.remove(at: try Self.index(id, revision: revision, records: records)) }
    }
    private static func index(_ id: UUID, revision: Int, records: [ShellScript]) throws -> Int {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw MCPFailure("Shell script not found. List saved scripts again.", code: .invalidArgument) }
        guard records[index].revision == revision else { throw MCPFailure("Shell script changed. Read its current revision before editing or deleting.", code: .sessionBusy) }
        return index
    }
    private func mutate(_ change: (inout [ShellScript]) throws -> Void) throws {
        let lock = try MCPComponentLock(directory: directory, filename: ".shell-scripts.lock")
        defer { withExtendedLifetime(lock) {} }
        var records = try load(); try change(&records)
        let data = try JSONEncoder().encode(Archive(version: 1, scripts: records))
        guard data.count <= Self.maximumBytes else { throw MCPFailure("Shell script library size limit reached.", code: .capacity) }
        let temporary = directory.appending(path: ".shell-scripts-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw MCPFailure("Cannot save Shell script library.", code: .policyUnavailable) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw MCPFailure("Cannot activate Shell script library.", code: .policyUnavailable) }
    }
}
