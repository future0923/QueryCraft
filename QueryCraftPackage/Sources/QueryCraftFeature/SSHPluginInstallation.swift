import Foundation
import Darwin

enum SSHPluginInstallation {
    /// Identity of the active plugin when this host may run it. A bundle signed
    /// for another distribution channel (for example the self-signed builds
    /// before Developer ID) cannot load here, so it must not block replacement
    /// by a verified release. Usable plugins keep the downgrade guard.
    static func usableActiveIdentity(in directory: URL) throws -> DatabaseDriverReleaseIdentity? {
        let current = SSHPlugin.bundleURL(in: directory).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: current.path),
              (try? SSHPlugin.verifySignature(at: current)) != nil else { return nil }
        guard let installed = Bundle(url: current),
              let version = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw MCPFailure("Cannot verify the installed SSH plugin version. Current was preserved.")
        }
        return DatabaseDriverReleaseIdentity(version: version, build: build)
    }

    /// Install a locally supplied bundle in an immutable version directory.
    /// Existing processes retain the old library; new clients see one atomic link.
    static func install(source: URL, directory: URL, preventsDowngrade: Bool = false) throws -> URL {
        let source = source.resolvingSymlinksInPath()
        guard source.pathExtension == "bundle", source.lastPathComponent == "QueryCraftSSH.bundle" else {
            throw MCPFailure("Choose a signed QueryCraftSSH.bundle directory.")
        }
        let root = directory.appending(path: "Plugins/SSH", directoryHint: .isDirectory)
        let versions = root.appending(path: "Versions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try MCPComponentLock(directory: root, filename: ".install.lock")
        defer { withExtendedLifetime(lock) {} }
        let id = UUID().uuidString
        let version = versions.appending(path: id, directoryHint: .isDirectory)
        let staged = version.appending(path: "QueryCraftSSH.bundle", directoryHint: .isDirectory)
        let temporaryLink = root.appending(path: ".current-" + id)
        var activated = false
        defer {
            try? FileManager.default.removeItem(at: temporaryLink)
            if !activated { try? FileManager.default.removeItem(at: version) }
        }
        // Validate source before copying, then validate the immutable copy before
        // executing its ABI version function. A failed install keeps Current.
        try SSHPlugin.verifySignature(at: source)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: staged)
        let plugin = try SSHPlugin(bundleURL: staged)
        withExtendedLifetime(plugin) {}
        // Recheck Current under the cross-process lock: another updater may
        // have activated a newer release while this caller was downloading.
        if preventsDowngrade {
            if let installed = try usableActiveIdentity(in: directory) {
                guard let candidate = Bundle(url: staged),
                      let newVersion = candidate.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      let newBuild = candidate.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                    throw MCPFailure("Cannot verify the installed SSH plugin version. Current was preserved.")
                }
                guard !installed.isNewer(than: .init(version: newVersion, build: newBuild)) else {
                    throw MCPFailure("Refusing an automatic SSH plugin downgrade.")
                }
            }
            try Task.checkCancellation()
        }
        try FileManager.default.createSymbolicLink(atPath: temporaryLink.path, withDestinationPath: "Versions/" + id)
        guard Darwin.rename(temporaryLink.path, root.appending(path: "Current").path) == 0 else {
            throw MCPFailure("Cannot activate SSH plugin. The previous version remains selected.")
        }
        activated = true
        return staged
    }
}
