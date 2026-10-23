import Foundation

/// Snapshots are immutable: an installed Current symlink may change while this
/// process continues using its original executable/module. Never dlopen Current
/// just to diagnose an update or infer capabilities from its metadata.
struct MCPBundleIdentity: Sendable, Equatable {
    let url: URL
    let identifier: String?
    let version: String?
    let build: String?
    let runtimeBuild: String?
    let appVersion: String?

    static func read(at url: URL) -> Self {
        // Bundle.main marks its URL as a directory; a symlink URL may not.
        // Normalize this flag too, or the same running app falsely looks stale.
        let resolved = URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
        let plist = resolved.appending(path: "Contents/Info.plist")
        let size = (try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let info: [String: Any]?
        if (1...65_536).contains(size), let data = try? Data(contentsOf: plist), data.count <= 65_536 {
            info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        } else { info = nil }
        func string(_ key: String) -> String? {
            guard let text = info?[key] as? String, !text.isEmpty, text.utf8.count <= 256,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return text
        }
        return Self(url: resolved, identifier: string("CFBundleIdentifier"), version: string("CFBundleShortVersionString"),
                    build: string("CFBundleVersion"), runtimeBuild: string("QCRuntimeBuild"), appVersion: string("QCAppVersion"))
    }
    var value: MCPJSONValue {
        .object(["identifier": identifier.map(MCPJSONValue.string) ?? .null,
                 "version": version.map(MCPJSONValue.string) ?? .null, "build": build.map(MCPJSONValue.string) ?? .null,
                 "runtime_build": runtimeBuild.map(MCPJSONValue.string) ?? .null,
                 "app_version": appVersion.map(MCPJSONValue.string) ?? .null])
    }
}

struct SSHPluginRuntimeInfo: Sendable {
    let bundle: MCPBundleIdentity
    let files: Bool
    let management: Bool
    let pooling: Bool
    let progress: Bool
    let routes: Bool
    let diagnostics: Bool
    var value: MCPJSONValue {
        .object(["bundle": bundle.value, "abi": 1, "extensions": .object([
            "files": files ? 1 : .null, "file_management": management ? 1 : .null,
            "pool": pooling ? 1 : .null, "progress": progress ? 1 : .null,
            "routes": routes ? 1 : .null, "diagnostics": diagnostics ? 1 : .null]),
            "authentication": .array((routes ? ["password", "private_key", "agent"] : ["password", "private_key"]).map(MCPJSONValue.string)),
            "maximum_jump_hosts": .int(routes ? 4 : 0), "transfer_resume": false])
    }
}

struct MCPRuntimeInfo: Sendable {
    let directory: URL
    let host: MCPBundleIdentity
    let startedAt: Date
    init(directory: URL, hostURL: URL = Bundle.main.bundleURL) {
        self.directory = directory; host = .read(at: hostURL); startedAt = Date()
    }
    func value(ssh: SSHPluginRuntimeInfo?) -> MCPJSONValue {
        let currentHost = MCPBundleIdentity.read(at: directory.appending(path: "MCP/Current"))
        let currentSSH = MCPBundleIdentity.read(at: SSHPlugin.bundleURL(in: directory))
        let managed = host.identifier == "io.github.future0923.QueryCraft.MCP" || host.identifier == "io.github.future0923.QueryCraft.MCP.Dev"
        let hostChanged: Bool? = managed ? currentHost != host : nil
        let sshChanged = ssh.map { $0.bundle != currentSSH } ?? (currentSSH.identifier != nil)
        return .object([
            "environment": .string(MCPServerIdentity(directory: directory).clientName),
            "started_at": .string(startedAt.ISO8601Format()),
            "host": .object(["loaded": host.value, "installed": currentHost.value,
                "comparison": .string(managed ? "managed" : "unmanaged_host"),
                "reconnect_required": hostChanged.map(MCPJSONValue.bool) ?? .null]),
            "ssh": .object(["loaded": ssh?.value ?? .null, "installed_metadata": currentSSH.value,
                "installed_state": .string(currentSSH.identifier == nil ? "missing_or_unreadable" : "metadata_present"),
                "reconnect_required": .bool(sshChanged)]),
            "reconnect_required": .bool(hostChanged == true || sshChanged),
            "recovery": .string(hostChanged == true || sshChanged ? "Reconnect this MCP client to load the installed runtime and plugins." : "No loaded/installed identity change detected."),
            "account_format_versions": .array([1, 2]), "automatic_retry": false
        ])
    }
}
