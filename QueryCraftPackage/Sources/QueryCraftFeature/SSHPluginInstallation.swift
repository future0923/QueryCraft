import Foundation
import Darwin

enum SSHPluginInstallation {
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
            let current = SSHPlugin.bundleURL(in: directory).resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: current.path) {
                guard let installed = Bundle(url: current), let candidate = Bundle(url: staged),
                      let oldVersion = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      let oldBuild = installed.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                      let newVersion = candidate.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      let newBuild = candidate.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                    throw MCPFailure("Cannot verify the installed SSH plugin version. Current was preserved.")
                }
                guard !DatabaseDriverReleaseIdentity(version: oldVersion, build: oldBuild)
                    .isNewer(than: .init(version: newVersion, build: newBuild)) else {
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
