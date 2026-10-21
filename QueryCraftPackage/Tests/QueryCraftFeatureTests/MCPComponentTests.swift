import CryptoKit
import Foundation
import Testing
@testable import QueryCraftFeature

private final class ComponentURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct MCPComponentTests {
    func release(kind: MCPComponentKind = .mcp, version: String = "0.1.0", api: Int = 5) -> MCPComponentRelease {
        .init(component: kind, version: version, build: "1", architectures: [DatabaseDriverArchitecture.current.rawValue],
              minimumAppVersion: "0.1.9", maximumAppVersionExclusive: "1.0.0", driverAPI: api, storageAPI: 1, credentialAPI: 1, desktopAPI: 1,
              minimumMCPVersion: kind == .skill ? "0.1.0" : nil, maximumMCPVersionExclusive: kind == .skill ? "1.0.0" : nil,
              sha256: String(repeating: "a", count: 64), size: 100, url: URL(string: "https://example.test/component.zip")!)
    }
    @Test func validatesHostAndOptionalSkillVersionRelations() throws {
        let host = MCPComponentHost(appVersion: "0.1.9")
        try release().validate(host: host, mcpVersion: nil)
        #expect(throws: MCPFailure.self) { try release(api: 6).validate(host: host, mcpVersion: nil) }
        #expect(throws: MCPFailure.self) { try release().validate(host: .init(appVersion: "0.1.8"), mcpVersion: nil) }
        #expect(throws: MCPFailure.self) { try release().validate(host: .init(appVersion: "1.0.0"), mcpVersion: nil) }
        #expect(throws: MCPFailure.self) { try release(kind: .skill).validate(host: host, mcpVersion: nil) }
        #expect(throws: MCPFailure.self) { try release(kind: .skill).validate(host: host, mcpVersion: "1.0.0") }
        try release(kind: .skill).validate(host: host, mcpVersion: "0.1.1")
    }
    @Test func signedRecordsFallbackAndTamperingAreVerified() async throws {
        let key = Curve25519.Signing.PrivateKey()
        func envelope(_ release: MCPComponentRelease) throws -> MCPComponentCatalog.Envelope {
            let payload = try JSONEncoder().encode(release)
            return .init(payload: payload, signature: try key.signature(for: payload))
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ComponentURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let catalog = MCPComponentCatalog(baseURL: URL(string: "https://example.test/components")!, publicKey: key.publicKey.rawRepresentation, session: session)
        let index = MCPComponentCatalog.Catalog(schemaVersion: 1, component: .mcp,
            releases: try [envelope(release(version: "0.2.0", api: 6)), envelope(release())])
        ComponentURLProtocol.response = try JSONEncoder().encode(index)
        #expect(try await catalog.latest(.mcp, host: .init(appVersion: "0.1.9")).version == "0.1.0")
        let payload = try JSONEncoder().encode(release(version: "0.3.0"))
        let forged = MCPComponentCatalog.Catalog(schemaVersion: 1, component: .mcp,
            releases: [.init(payload: payload, signature: index.releases[1].signature)])
        ComponentURLProtocol.response = try JSONEncoder().encode(forged)
        await #expect(throws: MCPFailure.self) { _ = try await catalog.releases(.mcp) }
        ComponentURLProtocol.response = try JSONEncoder().encode(MCPComponentCatalog.Catalog(schemaVersion: 1, component: .skill, releases: []))
        await #expect(throws: MCPFailure.self) { _ = try await catalog.releases(.mcp) }
        await #expect(throws: MCPFailure.self) { try await catalog.validateURL(URL(string: "http://example.test/component.zip")!) }
    }
    @Test func developmentSourceNeverFallsBackToProduction() async throws {
        let production = "https://querycraft.debug-tools.cc/components/"
        #expect(MCPComponentCatalog.configuredURL(identity: .production, environment: [:])?.absoluteString == production)
        #expect(MCPComponentCatalog.configuredURL(identity: .development, environment: [:], production: production) == nil)
        #expect(MCPComponentCatalog.configuredURL(identity: .development,
            environment: ["QUERYCRAFT_COMPONENT_CATALOG_BASE_URL": production]) == nil)
        #expect(MCPComponentCatalog.configuredURL(identity: .development,
            environment: ["QUERYCRAFT_DEV_COMPONENT_CATALOG_BASE_URL": production]) == nil)
        #expect(MCPComponentCatalog.configuredURL(identity: .development,
            environment: ["QUERYCRAFT_DEV_COMPONENT_CATALOG_BASE_URL": "https://dev.example.test/components/"])?.host == "dev.example.test")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ComponentURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let catalog = MCPComponentCatalog(session: session, identity: .development, environment: [:])
        let count = ComponentURLProtocol.requestCount
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "QueryCraftDev")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let sentinel = root.appending(path: "MCP/keep-existing-runtime")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing runtime".utf8).write(to: sentinel)
        await #expect(throws: MCPFailure.self) { _ = try await catalog.releases(.mcp) }
        await #expect(throws: MCPFailure.self) { _ = try await catalog.releases(.skill) }
        await #expect(throws: MCPFailure.self) { try await catalog.download(release(), to: root.appending(path: "download.zip")) }
        let installer = MCPInstallation(root: root.appending(path: "MCP"), catalog: catalog)
        await #expect(throws: MCPFailure.self) { try await installer.install() }
        let skill = MCPSkillInstallation(catalog: catalog, cache: root.appending(path: "SkillPackages"))
        await #expect(throws: MCPFailure.self) { try await skill.install(at: root.appending(path: "skills/querycraft-dev")) }
        #expect(ComponentURLProtocol.requestCount == count)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "existing runtime")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "download.zip").path))
    }

    @Test func processLockPreventsConcurrentInstallerMutation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try MCPComponentLock(directory: root)
        withExtendedLifetime(first) { #expect(throws: MCPFailure.self) { _ = try MCPComponentLock(directory: root) } }
    }
}
