import Foundation
import CryptoKit

enum MCPSkillTarget: String, CaseIterable, Sendable {
    case shared, codex, claude
    var title: String { switch self { case .shared: "Shared (.agents)"; case .codex: "Codex"; case .claude: "Claude Code" } }
    var directory: URL { directory(in: FileManager.default.homeDirectoryForCurrentUser) }
    func directory(in homeDirectory: URL, identity: MCPServerIdentity = .production) -> URL {
        let folder = switch self { case .shared: ".agents"; case .codex: ".codex"; case .claude: ".claude" }
        return homeDirectory.appending(path: "\(folder)/skills/\(identity.skillName)")
    }
}
actor MCPSkillInstallation {
    enum Status: String, Sendable { case notInstalled, current, updateAvailable, modified }
    struct Manifest: Codable { let version: String; let files: [String: String]; var build: String?; var release: MCPComponentRelease?; var environment: String? = nil }
    static let version = "1.0.0" // Local fixture compatibility; published versions come from the catalog.
    static let manifestName = ".querycraft-managed.json"
    private let identity: MCPServerIdentity
    private let sourceOverride: URL?
    private let catalog: MCPComponentCatalog
    private let host: MCPComponentHost
    private let cache: URL
    private var available: MCPComponentRelease?
    private var checkedMCPVersion: String?
    init(source: URL? = nil, catalog: MCPComponentCatalog? = nil,
         host: MCPComponentHost = .current, cache: URL = QueryCraftStorageLocation.applicationSupportDirectory.appending(path: "SkillPackages"),
         identity: MCPServerIdentity? = nil) {
        self.identity = identity ?? MCPServerIdentity(directory: cache.deletingLastPathComponent())
        sourceOverride = source; self.catalog = catalog ?? MCPComponentCatalog(identity: self.identity); self.host = host; self.cache = source.map { $0.deletingLastPathComponent().appending(path: ".skill-cache") } ?? cache
    }
    func checkForUpdates(mcpVersion: String?) async throws -> String {
        if sourceOverride != nil { return Self.version }
        let release = try await catalog.latest(.skill, host: host, mcpVersion: mcpVersion)
        available = release; checkedMCPVersion = mcpVersion
        return release.version
    }
    func installedVersion(at destination: URL) -> String? {
        guard let data = try? Data(contentsOf: destination.appending(path: Self.manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
        return manifest.version
    }
    func status(at destination: URL) throws -> Status {
        try rejectLink(destination)
        guard FileManager.default.fileExists(atPath: destination.path) else { return .notInstalled }
        let actual = try hashes(in: destination)
        guard let data = try? Data(contentsOf: destination.appending(path: Self.manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.files == actual else { return .modified }
        if identity == .development && manifest.environment != identity.clientName { return .updateAvailable }
        if let sourceOverride { return actual == (try expectedHashes(in: sourceOverride)) ? .current : .updateAvailable }
        if let release = manifest.release, let checkedMCPVersion,
           (try? release.validate(host: host, mcpVersion: checkedMCPVersion)) == nil { return .updateAvailable }
        if let available, DatabaseDriverReleaseIdentity(version: available.version, build: available.build)
            .isNewer(than: .init(version: manifest.version, build: manifest.build ?? "0")) { return .updateAvailable }
        return .current
    }
    func install(at destination: URL, mcpVersion: String? = nil,
                 onProgress: @escaping @Sendable (MCPComponentInstallationProgress) async -> Void = { _ in }) async throws {
        await onProgress(.init(phase: .checking))
        let fm = FileManager.default
        try rejectLink(destination.deletingLastPathComponent())
        let lock = try MCPComponentLock(directory: cache); defer { withExtendedLifetime(lock) {} }
        let state = try status(at: destination)
        guard state != .modified else { throw MCPFailure("This skill contains local or unmanaged changes. Preserve those changes before updating.") }
        let runtimeLock = try sourceOverride == nil ? MCPComponentLock(directory: cache.deletingLastPathComponent().appending(path: "MCP")) : nil
        defer { withExtendedLifetime(runtimeLock) {} }
        let activeMCPVersion: String?
        if sourceOverride == nil {
            let runtime = MCPInstallation(root: cache.deletingLastPathComponent().appending(path: "MCP"), catalog: catalog, host: host)
            activeMCPVersion = try await runtime.installedVersion()
        } else { activeMCPVersion = mcpVersion }
        let source: URL
        let version: String
        let build: String?
        let selectedRelease: MCPComponentRelease?
        let working = cache.appending(path: ".install-" + UUID().uuidString)
        defer { try? fm.removeItem(at: working) }
        if let sourceOverride { source = sourceOverride; version = Self.version; build = nil; selectedRelease = nil }
        else {
            let release = try await catalog.latest(.skill, host: host, mcpVersion: activeMCPVersion)
            available = release; checkedMCPVersion = activeMCPVersion
            try release.validate(host: host, mcpVersion: activeMCPVersion)
            if try status(at: destination) == .current { return }
            try fm.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let archive = working.appending(path: "download.zip")
            try await catalog.download(release, to: archive, onProgress: onProgress)
            await onProgress(.init(phase: .extracting))
            let unpacked = working.appending(path: "unpacked")
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await MCPComponentArchive.extract(archive, into: unpacked, root: "QueryCraftSkill")
            try release.verifyPayload(at: unpacked.appending(path: "QueryCraftSkill/component.json"))
            source = unpacked.appending(path: "QueryCraftSkill/querycraft")
            version = release.version; build = release.build; selectedRelease = release
        }
        await onProgress(.init(phase: .verifying))
        let bundled = try expectedHashes(in: source)
        guard bundled["SKILL.md"] != nil else { throw MCPFailure("QueryCraft skill entrypoint is missing.") }
        if state == .current, let sourceOverride, try expectedHashes(in: sourceOverride) == hashes(in: destination) { return }
        let parent = destination.deletingLastPathComponent()
        await onProgress(.init(phase: .installing))
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appending(path: ".querycraft-install-" + UUID().uuidString)
        let backup = parent.appending(path: ".querycraft-backup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        if identity == .development { try developmentEntrypoint(in: source).write(to: staged.appending(path: "SKILL.md"), options: .atomic) }
        let manifest = Manifest(version: version, files: bundled, build: build, release: selectedRelease,
            environment: identity == .development ? identity.clientName : nil)
        try JSONEncoder().encode(manifest).write(to: staged.appending(path: Self.manifestName), options: .atomic)
        guard try hashes(in: staged) == bundled else { throw MCPFailure("Skill staging verification failed.") }
        // Recheck after the network await, preserving edits made during download.
        guard try status(at: destination) != .modified else { throw MCPFailure("Skill changed during download and was preserved.") }
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staged, to: destination) }
        catch { if existed { try fm.moveItem(at: backup, to: destination) }; throw error }
        if existed { try? fm.removeItem(at: backup) }
    }
    func uninstall(at destination: URL) throws {
        let lock = try MCPComponentLock(directory: cache); defer { withExtendedLifetime(lock) {} }
        try rejectLink(destination.deletingLastPathComponent())
        let state = try status(at: destination)
        guard state != .modified else { throw MCPFailure("This skill has local or unmanaged changes and was preserved.") }
        if state != .notInstalled { try FileManager.default.removeItem(at: destination) }
    }
    private func expectedHashes(in source: URL) throws -> [String: String] {
        var files = try hashes(in: source)
        if identity == .development {
            files["SKILL.md"] = SHA256.hash(data: try developmentEntrypoint(in: source)).map { String(format: "%02x", $0) }.joined()
        }
        return files
    }
    private func developmentEntrypoint(in source: URL) throws -> Data {
        let text = try String(contentsOf: source.appending(path: "SKILL.md"), encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
              let name = lines[1..<end].firstIndex(where: { $0 == "name: querycraft" }),
              let description = lines[1..<end].firstIndex(where: { $0.hasPrefix("description:") }) else {
            throw MCPFailure("Cannot identify the QueryCraft skill entrypoint; the downloaded source was preserved.")
        }
        lines[name] = "name: querycraft-dev"
        lines[description] = "description: Use QueryCraft Dev MCP for database work explicitly targeting the development environment. Requires the querycraft-dev MCP server; use the querycraft skill for the production environment."
        var body = lines[(end + 1)...].joined(separator: "\n")
        body = body.replacingOccurrences(of: "# QueryCraft\n", with: "# QueryCraft Dev\n")
        body = "\nUse only the `querycraft-dev` MCP server (`QueryCraft Dev`) for this skill. Clients may normalize its server prefix. If this server is unavailable, reconnect it; do not fall back to `querycraft`. Database permissions still come from the selected server.\n" + body
        return Data((lines[...end].joined(separator: "\n") + "\n" + body).utf8)
    }

    private func rejectLink(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
            throw MCPFailure("Refusing to replace a symbolic link in the skill installation.")
        }
    }
    private func hashes(in directory: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        func visit(_ folder: URL, relative: String) throws {
            try rejectLink(folder)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                try rejectLink(url)
                let key = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true { try visit(url, relative: key) }
                else if values.isRegularFile == true, key != Self.manifestName {
                    files[key] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        // Derive relative names during traversal, avoiding /var vs /private/var URL normalization.
        try visit(directory, relative: "")
        return files
    }
}
