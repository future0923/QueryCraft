import Foundation
import MCP
import Testing
@_spi(MCP) @testable import QueryCraftFeature
@testable import QueryCraftMCPRuntime

struct MCPInitializationTests {
    // Captured from the installed Codex app-server's actual conversation MCP
    // connection, not its separate settings-page discovery connection.
    static let codexInitialize = Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"extensions":{"openai/form":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.162.0-alpha.17.2"}}}"#.utf8)

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func codexConversationHandshakeDiscoversAndCallsTools(development: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .appending(path: development ? "QueryCraftDev" : "QueryCraft")
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let runtime = MCPHostRuntime(directory: root)
        let server = await QueryCraftMCPApplication.makeServer(runtime: runtime)
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: MCPInitializationTransport(pair.server))
        try await pair.client.connect()
        var replies = await pair.client.receive().makeAsyncIterator()

        try await pair.client.send(Self.codexInitialize)
        let initialized = try JSONDecoder().decode(Response<Initialize>.self, from: #require(try await replies.next()))
        let info = try initialized.result.get()
        #expect(info.protocolVersion == "2025-06-18")
        #expect(info.serverInfo.name == (development ? "QueryCraft Dev" : "QueryCraft"))
        try await pair.client.send(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        try await pair.client.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8))
        let listed = try JSONDecoder().decode(Response<ListTools>.self, from: #require(try await replies.next()))
        #expect(try listed.result.get().tools.contains { $0.name == "querycraft_list_connections" })

        let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"querycraft_list_connections","arguments":{}}}"#.utf8)
        try await pair.client.send(call)
        let allowed = try JSONDecoder().decode(Response<CallTool>.self, from: #require(try await replies.next()))
        #expect(try allowed.result.get().isError != true)
        policy.enabled = false; try store.save(policy)
        try await pair.client.send(call)
        let denied = try JSONDecoder().decode(Response<CallTool>.self, from: #require(try await replies.next()))
        #expect(try denied.result.get().isError == true)
        await pair.client.disconnect(); await server.stop(); await runtime.shutdown()
    }

    @Test func compatibilityPreservesKnownCapabilitiesAndRequestIdentity() throws {
        var request = try #require(try JSONSerialization.jsonObject(with: Self.codexInitialize) as? [String: Any])
        var params = try #require(request["params"] as? [String: Any])
        var caps = try #require(params["capabilities"] as? [String: Any])
        caps["experimental"] = ["object": ["nested": true], "boolean": true, "number": 2, "array": [1], "null": NSNull(), "legacy": "value"] as [String: Any]
        params["capabilities"] = caps; request["params"] = params
        let normalized = MCPInitializationTransport.compatibleInitialization(try JSONSerialization.data(withJSONObject: request))
        let result = try JSONDecoder().decode(Request<Initialize>.self, from: normalized)
        #expect(result.id == .number(0))
        #expect(result.params.clientInfo.title == "Codex")
        #expect(result.params.capabilities.elicitation?.url != nil)
        #expect(result.params.capabilities.experimental == ["legacy": "value"])
        let json = try #require(try JSONSerialization.jsonObject(with: normalized) as? [String: Any])
        let actualParams = try #require(json["params"] as? [String: Any])
        let actualCaps = try #require(actualParams["capabilities"] as? [String: Any])
        #expect((actualCaps["extensions"] as? NSDictionary) == (caps["extensions"] as? NSDictionary))
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"querycraft_execute_query","arguments":{"experimental":{"x":{}}}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"x":"legacy"}}}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#,
        "invalid JSON"
    ])
    func leavesUnrelatedAndMalformedMessagesUnchanged(_ raw: String) {
        let data = Data(raw.utf8)
        #expect(MCPInitializationTransport.compatibleInitialization(data) == data)
    }
}
