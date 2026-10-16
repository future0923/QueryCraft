import CryptoKit
import Foundation

enum MCPComponentKind: String, Codable, Sendable { case mcp, skill }

struct MCPComponentHost: Codable, Equatable, Sendable {
    let appVersion: String
    var driverAPI = DatabaseDriverCompatibilityValidator.currentDriverAPIVersion
    var storageAPI = 1
    var credentialAPI = 1
    var desktopAPI = 1
    static var current: Self {
        .init(appVersion: Bundle.main.object(forInfoDictionaryKey: "QCAppVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }
}

struct MCPComponentRelease: Codable, Equatable, Sendable {
    let component: MCPComponentKind
    let version: String
    let build: String
    let architectures: [String]
    let minimumAppVersion: String
    let maximumAppVersionExclusive: String?
    let driverAPI: Int
    let storageAPI: Int
    let credentialAPI: Int
    let desktopAPI: Int
    let minimumMCPVersion: String?
    let maximumMCPVersionExclusive: String?
    let sha256: String
    let size: Int64
    let url: URL
    var identity: String { "\(version)-\(build)" }
    func verifyPayload(at url: URL) throws {
        var expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        for key in ["sha256", "size", "url"] { expected.removeValue(forKey: key) }
        guard let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              NSDictionary(dictionary: actual).isEqual(to: expected) else {
            throw MCPFailure("Component payload compatibility metadata does not match its signed catalog.")
        }
    }
    func newer(than other: Self) -> Bool {
        DatabaseDriverReleaseIdentity(version: version, build: build)
            .isNewer(than: .init(version: other.version, build: other.build))
    }
    func validate(host: MCPComponentHost, architecture: String = DatabaseDriverArchitecture.current.rawValue,
                  mcpVersion: String?) throws {
        let validVersion: (String) -> Bool = { value in
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }
        }
        guard validVersion(version), !build.isEmpty, build.allSatisfy(\.isNumber), Int(build) != nil,
              validVersion(minimumAppVersion), maximumAppVersionExclusive.map(validVersion) ?? true,
              minimumMCPVersion.map(validVersion) ?? true, maximumMCPVersionExclusive.map(validVersion) ?? true,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }), size > 0, size <= 536_870_912 else {
            throw MCPFailure(AppCopy.current.text("组件清单格式不正确。", "Invalid component manifest."))
        }
        guard host.appVersion.compare(minimumAppVersion, options: .numeric) != .orderedAscending,
              maximumAppVersionExclusive.map({ host.appVersion.compare($0, options: .numeric) == .orderedAscending }) ?? true,
              driverAPI == host.driverAPI, storageAPI == host.storageAPI,
              credentialAPI == host.credentialAPI, desktopAPI == host.desktopAPI,
              component == .skill || architectures.contains(architecture) else {
            throw MCPFailure(AppCopy.current.text("此组件与当前 QueryCraft、驱动接口或系统架构不兼容。", "This component is incompatible with QueryCraft, its driver interfaces or this architecture."))
        }
        if component == .skill {
            guard let mcpVersion, let minimumMCPVersion,
                  mcpVersion.compare(minimumMCPVersion, options: .numeric) != .orderedAscending,
                  maximumMCPVersionExclusive.map({ mcpVersion.compare($0, options: .numeric) == .orderedAscending }) ?? true else {
                throw MCPFailure(AppCopy.current.text("请先安装兼容版本的 MCP 程序。", "Install a compatible MCP runtime first."))
            }
        }
    }
}

struct MCPComponentIndex: Codable, Sendable {
    let schemaVersion: Int
    let component: MCPComponentKind
    let releases: [MCPComponentRelease]
}

/// The same HTTPS distribution origin as drivers, with an Ed25519-signed catalog.
/// Package metadata is checked again after extraction, before any installed file changes.
actor MCPComponentCatalog {
    struct Envelope: Codable { let payload: Data; let signature: Data }
    struct Catalog: Codable { let schemaVersion: Int; let component: MCPComponentKind; let releases: [Envelope] }
    static let publicKey = "8dcu6cE1Vh6kUXtkeuDsSEWIy6sLbuHaqdnnZhE3rP8="
    let baseURL: URL
    private let key: Data
    private let session: URLSession
    private let allowsLocalHTTP: Bool
    init(baseURL: URL? = nil, publicKey: Data? = nil, session: URLSession = .shared,
         allowsLocalHTTP: Bool = false) {
        self.baseURL = baseURL ?? URL(string: ProcessInfo.processInfo.environment["QUERYCRAFT_COMPONENT_CATALOG_BASE_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "QCComponentCatalogBaseURL") as? String
            ?? "https://querycraft.debug-tools.cc/components/") ?? URL(string: "https://querycraft.debug-tools.cc/components/")!
        key = publicKey ?? Data(base64Encoded: Bundle.main.object(forInfoDictionaryKey: "QCComponentPublicKey") as? String ?? Self.publicKey) ?? Data()
        self.session = session
        #if DEBUG
        self.allowsLocalHTTP = allowsLocalHTTP || ["127.0.0.1", "localhost", "::1"].contains(self.baseURL.host ?? "")
        #else
        self.allowsLocalHTTP = false
        #endif
    }
    func validateURL(_ url: URL) throws {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (allowsLocalHTTP && url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")) else {
            throw MCPFailure(AppCopy.current.text("组件下载必须使用 HTTPS。", "Component downloads require HTTPS."))
        }
    }
    func releases(_ component: MCPComponentKind) async throws -> [MCPComponentRelease] {
        let file = component == .mcp ? "mcp-\(DatabaseDriverArchitecture.current.rawValue).json" : "skill.json"
        let url = baseURL.appending(path: file)
        try validateURL(url)
        let (data, response) = try await session.data(for: request(url))
        try validate(response)
        guard data.count <= 1_048_576 else { throw MCPFailure("Component catalog exceeds its size limit.") }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
        guard catalog.schemaVersion == 1, catalog.component == component, catalog.releases.count <= 256 else {
            throw MCPFailure("Invalid component catalog schema.")
        }
        let releases = try catalog.releases.map { envelope in
            guard publicKey.isValidSignature(envelope.signature, for: envelope.payload) else {
                throw MCPFailure(AppCopy.current.text("组件发行记录签名无效。", "Invalid component release signature."))
            }
            return try JSONDecoder().decode(MCPComponentRelease.self, from: envelope.payload)
        }
        guard releases.allSatisfy({ $0.component == component }),
              Set(releases.map(\.identity)).count == releases.count else {
            throw MCPFailure("Invalid component catalog schema or duplicate release.")
        }
        return releases.sorted { $0.newer(than: $1) }
    }
    func latest(_ component: MCPComponentKind, host: MCPComponentHost, mcpVersion: String? = nil) async throws -> MCPComponentRelease {
        let releases = try await releases(component)
        guard let release = releases.first(where: { (try? $0.validate(host: host, mcpVersion: mcpVersion)) != nil }) else {
            throw MCPFailure(AppCopy.current.text("目录中没有与当前版本兼容的组件。请检查组件发布状态或升级 QueryCraft。", "No compatible component is published. Check component availability or upgrade QueryCraft."))
        }
        try validateURL(release.url)
        return release
    }
    func download(_ release: MCPComponentRelease, to destination: URL,
                  onProgress: @escaping @Sendable (MCPComponentInstallationProgress) async -> Void = { _ in }) async throws {
        try validateURL(release.url)
        await onProgress(.init(phase: .downloading, totalBytes: release.size))
        let (bytes, response) = try await session.bytes(for: request(release.url))
        try validate(response)
        let temporary = destination.deletingLastPathComponent().appending(path: ".download-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MCPFailure("Cannot create component download file.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var received: Int64 = 0
        let clock = ContinuousClock()
        var sample = clock.now
        var sampleBytes: Int64 = 0
        var speed: Double?
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            guard received <= release.size else {
                throw MCPFailure(AppCopy.current.text("组件下载超过清单大小，已保留原版本。", "Component download exceeds its manifest size; the installed version was preserved."))
            }
            if buffer.count == 65_536 {
                try output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            // Time-based updates also report small chunks on low-bandwidth links.
            // Buffering disk writes separately avoids waiting for a large buffer to fill.
            if received.isMultiple(of: 256) {
                try Task.checkCancellation()
                let now = clock.now
                let duration = sample.duration(to: now)
                if duration >= .milliseconds(200) {
                    let parts = duration.components
                    let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                    speed = Double(received - sampleBytes) / seconds
                    await onProgress(.init(phase: .downloading, receivedBytes: received,
                                           totalBytes: release.size, bytesPerSecond: speed))
                    sample = now; sampleBytes = received
                }
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty { try output.write(contentsOf: buffer) }
        await onProgress(.init(phase: .downloading, receivedBytes: received,
                               totalBytes: release.size, bytesPerSecond: speed))
        await onProgress(.init(phase: .verifying))
        let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
        guard size?.int64Value == release.size, try Self.sha256(temporary) == release.sha256.lowercased() else {
            throw MCPFailure(AppCopy.current.text("组件下载大小或摘要校验失败，已保留原版本。", "Component size or checksum verification failed; the installed version was preserved."))
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    private func request(_ url: URL) -> URLRequest {
        var request = DatabaseDriverPackageInstaller.uncachedRequest(for: url)
        request.timeoutInterval = 120
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), let url = response.url else {
            throw MCPFailure(AppCopy.current.text("组件服务暂时不可用，请重新检查。", "The component service is unavailable. Check again to retry."))
        }
        try validateURL(url)
    }
    nonisolated static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
