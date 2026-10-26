import Foundation

actor SSHPluginManager {
    static let shared = SSHPluginManager()
    let directory: URL
    private let catalog: MCPComponentCatalog
    private var busy = false
    init(directory: URL = QueryCraftStorageLocation.applicationSupportDirectory, catalog: MCPComponentCatalog? = nil) {
        self.directory = directory
        self.catalog = catalog ?? MCPComponentCatalog(identity: MCPServerIdentity(directory: directory))
    }
    func installedVersion() throws -> String? {
        let url = SSHPlugin.bundleURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try SSHPlugin(bundleURL: url)
        return Bundle(url: url.resolvingSymlinksInPath())?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    func available() async throws -> MCPComponentRelease {
        try await catalog.latest(.ssh, host: .current)
    }
    func install(release: MCPComponentRelease,
                 progress: @escaping @Sendable (MCPComponentInstallationProgress) async -> Void) async throws {
        guard !busy else { throw MCPFailure("An SSH plugin operation is running.") }
        busy = true; defer { busy = false }
        guard release.component == .ssh else { throw MCPFailure("Invalid SSH release.") }
        try release.validate(host: .current, mcpVersion: nil)
        let staging = try makeStage(); defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appending(path: "ssh.zip")
        try await catalog.download(release, to: archive, onProgress: progress)
        await progress(.init(phase: .extracting))
        let bundle = try await extract(archive, into: staging.appending(path: "unpacked"))
        guard let info = Bundle(url: bundle), info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              info.object(forInfoDictionaryKey: "CFBundleVersion") as? String == release.build else { throw MCPFailure("SSH package version does not match the catalog.") }
        if let installed = try installedVersion() {
            let current = Bundle(url: SSHPlugin.bundleURL(in: directory).resolvingSymlinksInPath())
            let identity = DatabaseDriverReleaseIdentity(version: installed,
                build: current?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
            guard !identity.isNewer(than: .init(version: release.version, build: release.build)) else {
                throw MCPFailure("Refusing an automatic SSH plugin downgrade.")
            }
        }
        try release.verifyPayload(at: bundle.appending(path: "Contents/Resources/component.json"))
        try Task.checkCancellation()
        await progress(.init(phase: .installing))
        _ = try SSHPluginInstallation.install(source: bundle, directory: directory, preventsDowngrade: true)
    }
    func importPackage(_ source: URL) async throws {
        guard !busy else { throw MCPFailure("An SSH plugin operation is running.") }
        busy = true; defer { busy = false }
        let staging = try makeStage(); defer { try? FileManager.default.removeItem(at: staging) }
        let bundle = source.pathExtension.lowercased() == "zip"
            ? try await extract(source, into: staging.appending(path: "unpacked")) : source
        try Task.checkCancellation()
        _ = try SSHPluginInstallation.install(source: bundle, directory: directory)
    }
    func uninstall() throws {
        guard !busy else { throw MCPFailure("An SSH plugin operation is running.") }
        let root = directory.appending(path: "Plugins/SSH")
        let lock = try MCPComponentLock(directory: root, filename: ".install.lock"); defer { withExtendedLifetime(lock) {} }
        let current = root.appending(path: "Current")
        if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.removeItem(at: current) }
        // Loaded libraries and their resources remain intact until old MCP clients exit.
    }
    private func makeStage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "querycraft-ssh-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func extract(_ archive: URL, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await MCPComponentArchive.extract(archive, into: directory, root: "QueryCraftSSH.bundle")
        return directory.appending(path: "QueryCraftSSH.bundle")
    }
}
