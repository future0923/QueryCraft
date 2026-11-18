import Foundation
import Testing
@_spi(MCP) @testable import QueryCraftFeature
@testable import QueryCraftMCPRuntime

struct MCPEmbeddedServiceTests {
    @Test func embeddedServicePreservesHTTPAuthorizationAndStopsCleanly() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPPolicyStore(directory: directory)
        var policy = MCPPolicy()
        policy.enabled = true
        policy.http.port = Int.random(in: 49_152...65_535)
        try store.save(policy)
        let service = QueryCraftMCPEmbeddedService()
        try await service.start(directory: directory)
        do {
            #expect(await service.isRunning())
            var request = URLRequest(url: try #require(URL(string: policy.http.endpoint)))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Store integration test","version":"1"}}}"#.utf8)
            let (_, denied) = try await URLSession.shared.data(for: request)
            #expect((denied as? HTTPURLResponse)?.statusCode == 401)
            request.setValue("Bearer " + policy.http.token, forHTTPHeaderField: "Authorization")
            let (_, allowed) = try await URLSession.shared.data(for: request)
            try #require((allowed as? HTTPURLResponse)?.statusCode == 200)
            #expect((allowed as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id") != nil)
            policy.enabled = false
            try store.save(policy)
            let (_, revoked) = try await URLSession.shared.data(for: request)
            #expect((revoked as? HTTPURLResponse)?.statusCode == 403)
            try await service.stop()
            #expect(await !service.isRunning())
            policy.enabled = true
            try store.save(policy)
            try await service.start(directory: directory)
            #expect(await service.isRunning(), "The socket must be reusable after stop")
            try await service.stop()
        } catch {
            try? await service.stop()
            throw error
        }
    }
}
