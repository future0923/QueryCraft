import CryptoKit
import Foundation
import Testing
@testable import QueryCraftFeature

private final class ComponentURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
    @Test func processLockPreventsConcurrentInstallerMutation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try MCPComponentLock(directory: root)
        withExtendedLifetime(first) { #expect(throws: MCPFailure.self) { _ = try MCPComponentLock(directory: root) } }
    }
}
