import Foundation
import MCP
import Testing
@_spi(MCP) @testable import QueryCraftFeature
@testable import QueryCraftMCPRuntime

struct MCPHandshakeTests {
    @Test func sdkHandshakeAndToolPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPPolicyStore(directory: directory); var policy = MCPPolicy(); policy.enabled = true
        policy.disabledTools.insert("remove_connection"); try store.save(policy)
        let runtime = MCPHostRuntime(directory: directory)
        let server = await QueryCraftMCPApplication.makeServer(runtime: runtime)
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: pair.server)
        let client = Client(name: "test", version: "1")
        let initialized = try await client.connect(transport: pair.client)
        #expect(initialized.serverInfo.name == "QueryCraft")
        let (tools, _) = try await client.listTools()
        #expect(tools.contains(where: { $0.name == "querycraft_execute_query" }))
        #expect(!tools.contains(where: { $0.name == "querycraft_remove_connection" }))
        policy.enabled = false; try store.save(policy)
        let (content, isError) = try await client.callTool(name: "querycraft_list_connections")
        #expect(isError == true); #expect(!content.isEmpty)
        await client.disconnect(); await server.stop(); await runtime.shutdown()
    }
}
