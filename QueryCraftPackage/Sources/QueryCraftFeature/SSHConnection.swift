import Foundation
import Darwin

enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case password, privateKey = "private_key", agent
}

struct SSHConnection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var hostFingerprint: String
    var privateKeyPath: String?
    var storesCredential: Bool
    var authentication: SSHAuthentication? = nil
    var agentSocketPath: String? = nil
    var jumpConnectionID: UUID? = nil
    var groupID: UUID? = nil
    var sortIndex: Int? = nil
    var authenticationMethod: SSHAuthentication { authentication ?? (privateKeyPath == nil ? .password : .privateKey) }

    func validate() throws {
        let strings = [name, host, username, hostFingerprint] + [privateKeyPath].compactMap { $0 }
        guard strings.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
              name.utf8.count <= 256, host.utf8.count <= 253, username.utf8.count <= 256,
              !host.contains(where: { $0.isWhitespace }), (1...65535).contains(port),
              hostFingerprint.hasPrefix("SHA256:"), hostFingerprint.count == 50,
              Data(base64Encoded: String(hostFingerprint.dropFirst(7)) + "=")?.count == 32,
              privateKeyPath.map({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }) ?? (storesCredential || authenticationMethod == .agent),
              jumpConnectionID != id,
              authenticationMethod != .agent || (privateKeyPath == nil && !storesCredential),
              authenticationMethod != .password || privateKeyPath == nil,
              authenticationMethod != .privateKey || privateKeyPath != nil,
              agentSocketPath.map({ authenticationMethod == .agent && $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count < 104 }) ?? true else {
            throw MCPFailure("Invalid SSH connection. Supply an exact SHA256 host fingerprint, valid address and consistent password/key/agent authentication. Key and agent paths must be absolute; agent socket paths must be shorter than 104 UTF-8 bytes.")
        }
    }

    var value: MCPJSONValue {
        .object(["connection_id": .string(id.uuidString), "name": .string(name), "host": .string(host),
                 "port": .int(port), "username": .string(username), "host_fingerprint": .string(hostFingerprint),
                 "authentication": .string(authenticationMethod.rawValue),
                 "jump_connection_id": jumpConnectionID.map { .string($0.uuidString) } ?? .null])
    }
}

/// Separate from database grants: allConnections must never grant shell access.
struct MCPSSHPolicy: Codable, Equatable, Sendable {
    var connectionIDs: Set<UUID> = []
    var executionConnectionIDs: Set<UUID> = []
    var fileReadConnectionIDs: Set<UUID> = []
    var fileTransferConnectionIDs: Set<UUID> = []
    var fileManagementConnectionIDs: Set<UUID> = []
    init(connectionIDs: Set<UUID> = [], executionConnectionIDs: Set<UUID> = [],
         fileReadConnectionIDs: Set<UUID> = [], fileTransferConnectionIDs: Set<UUID> = [], fileManagementConnectionIDs: Set<UUID> = []) {
        self.connectionIDs = connectionIDs; self.executionConnectionIDs = executionConnectionIDs
        self.fileManagementConnectionIDs = fileManagementConnectionIDs
        self.fileReadConnectionIDs = fileReadConnectionIDs; self.fileTransferConnectionIDs = fileTransferConnectionIDs
    }
    private enum CodingKeys: String, CodingKey { case connectionIDs, executionConnectionIDs, fileReadConnectionIDs, fileTransferConnectionIDs, fileManagementConnectionIDs }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connectionIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .connectionIDs) ?? []
        executionConnectionIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .executionConnectionIDs) ?? []
        fileReadConnectionIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .fileReadConnectionIDs) ?? []
        fileManagementConnectionIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .fileManagementConnectionIDs) ?? []
        fileTransferConnectionIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .fileTransferConnectionIDs) ?? []
    }
}

/// Private, atomically replaced configuration. Cross-process lock prevents two
/// stdio/HTTP clients from overwriting each other's connection edits.
struct SSHConnectionStore: Sendable {
    let directory: URL
    var url: URL { directory.appending(path: "ssh-connections.json") }

    private struct Archive: Codable {
        let version: Int
        let connections: [SSHConnection]
    }
    func load() throws -> [SSHConnection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url), decoder = JSONDecoder()
            let profiles: [SSHConnection]
            if let archive = try? decoder.decode(Archive.self, from: data) {
                guard archive.version == 2 else { throw MCPFailure("Unsupported SSH account format.") }
                profiles = archive.connections
            } else { profiles = try decoder.decode([SSHConnection].self, from: data) }
            guard profiles.count <= 256, Set(profiles.map(\.id)).count == profiles.count else { throw MCPFailure("Invalid SSH connections.") }
            try profiles.forEach { try $0.validate() }; try Self.validateRoutes(profiles)
            return profiles
        } catch { throw MCPFailure("SSH connection configuration cannot be read. Repair ssh-connections.json.", code: .policyUnavailable) }
    }

    static func route(to profile: SSHConnection, in profiles: [SSHConnection]) throws -> [SSHConnection] {
        var reverse: [SSHConnection] = [], seen: Set<UUID> = [profile.id], current = profile
        while let id = current.jumpConnectionID {
            guard reverse.count < 4, seen.insert(id).inserted else { throw MCPFailure("SSH jump chain contains a cycle or exceeds four hops.") }
            guard let parent = profiles.first(where: { $0.id == id }) else { throw MCPFailure("Saved SSH jump host was not found.", code: .connectionNotFound) }
            reverse.append(parent); current = parent
        }
        return reverse.reversed()
    }
    static func validateRoutes(_ profiles: [SSHConnection]) throws {
        for profile in profiles { _ = try route(to: profile, in: profiles) }
    }
    func insert(_ profile: SSHConnection) throws {
        try profile.validate()
        try mutate { profiles in
            guard profiles.count < 256, !profiles.contains(where: { $0.id == profile.id }) else {
                throw MCPFailure("SSH connection capacity reached.", code: .capacity)
            }
            profiles.append(profile)
        }
    }

    func remove(id: UUID) throws {
        try mutate { profiles in
            guard !profiles.contains(where: { $0.jumpConnectionID == id }) else { throw MCPFailure("This server is used as a jump host. Update its dependent connections first.") }
            profiles.removeAll { $0.id == id }
        }
    }

    func replace(_ profile: SSHConnection, expecting original: SSHConnection) throws {
        try profile.validate()
        try mutate { profiles in
            guard profile.id == original.id, let index = profiles.firstIndex(where: { $0.id == original.id }),
                  profiles[index] == original else {
                throw MCPFailure(AppCopy.current.text("连接已被修改，请重新打开后编辑。", "The connection changed. Reopen it before editing."))
            }
            profiles[index] = profile
        }
    }

    func move(_ profile: SSHConnection, to groupID: UUID?, beforeID: UUID?) throws {
        try mutate { profiles in
            guard let index = profiles.firstIndex(of: profile) else { throw MCPFailure("Connection changed. Reload it.") }
            profiles[index].groupID = groupID
            let moved = profiles[index]
            var destination = profiles.filter { $0.groupID == groupID && $0.id != profile.id }
                .sorted { ($0.sortIndex ?? Int.max) < ($1.sortIndex ?? Int.max) }
            destination.insert(moved, at: beforeID.flatMap { id in destination.firstIndex { $0.id == id } } ?? destination.count)
            for (order, entry) in destination.enumerated() {
                if let index = profiles.firstIndex(where: { $0.id == entry.id }) { profiles[index].sortIndex = order }
            }
        }
    }

    /// First migration keeps a private rollback snapshot. V2 intentionally
    /// rejects legacy array-only readers so they cannot ignore a saved jump.
    private func backupLegacy(_ data: Data) throws {
        let backup = directory.appending(path: ".ssh-connections-v1.backup.json")
        let descriptor = Darwin.open(backup.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            var info = stat()
            guard errno == EEXIST, Darwin.lstat(backup.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size > 0 else {
                throw MCPFailure("Cannot create a private legacy SSH account backup.", code: .policyUnavailable)
            }
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var saved = false
        defer { try? handle.close(); if !saved { _ = Darwin.unlink(backup.path) } }
        try handle.write(contentsOf: data); try handle.synchronize(); saved = true
    }

    private func mutate(_ update: (inout [SSHConnection]) throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appending(path: ".ssh-connections.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw MCPFailure("Cannot lock SSH connections.", code: .policyUnavailable) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw MCPFailure("Cannot lock SSH connections.", code: .policyUnavailable) }
        defer { flock(lock, LOCK_UN) }
        var profiles = try load()
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let wasVersioned = previous.flatMap { try? JSONDecoder().decode(Archive.self, from: $0) } != nil
        try update(&profiles); try Self.validateRoutes(profiles)
        let versioned = wasVersioned || profiles.contains { $0.authenticationMethod == .agent || $0.jumpConnectionID != nil }
        if versioned && !wasVersioned, let previous { try backupLegacy(previous) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = directory.appending(path: ".ssh-connections-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw MCPFailure("Cannot save SSH connections.", code: .policyUnavailable) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        let data: Data
        if versioned { data = try encoder.encode(Archive(version: 2, connections: profiles)) }
        else { data = try encoder.encode(profiles) }
        try file.write(contentsOf: data); try file.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw MCPFailure("Cannot save SSH connections.", code: .policyUnavailable) }
    }
}
