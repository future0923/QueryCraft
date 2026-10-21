import Foundation
import MCP
import Testing
@_spi(MCP) @testable import QueryCraftFeature

struct MCPHostBoundaryTests {
    @Test func sharedToolSchemasRoundtripThroughSDKWithoutChangingHints() throws {
        for definition in MCPToolCatalog.definitions {
            let tool = try JSONDecoder().decode(Tool.self, from: JSONEncoder().encode(definition.tool))
            #expect(tool.name == "querycraft_" + definition.name)
            #expect(tool.description == definition.description)
            #expect(tool.annotations.readOnlyHint == MCPToolCatalog.readTools.contains(definition.name))
            #expect(tool.annotations.destructiveHint == !MCPToolCatalog.readTools.contains(definition.name))
            #expect(tool.inputSchema.objectValue?["additionalProperties"] == false)
            #expect(tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) == definition.required)
        }
    }

    @Test(arguments: [
        #"{"v":9223372036854775807,"b":true,"n":null,"s":"中文👋","a":[1,1.5,false,{}]}"#,
        #"{"s":"data:text/plain;base64,SGVsbG8=","negative":-42,"e":1.2e3}"#
    ])
    func jsonBoundaryPreservesWireValues(_ raw: String) throws {
        let data = Data(raw.utf8)
        let shared = try JSONDecoder().decode(MCPJSONValue.self, from: data)
        let decoded = try JSONDecoder().decode(MCP.Value.self, from: JSONEncoder().encode(shared))
        #expect(decoded == (try JSONDecoder().decode(MCP.Value.self, from: data)))
    }

    @Test func typedErrorAndResourceRevocationCrossTheHostBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = MCPPolicy(); policy.enabled = true
        let store = MCPPolicyStore(directory: root); try store.save(policy)
        let runtime = MCPHostRuntime(directory: root)
        #expect(try runtime.resourceTools().contains("list_tables"))
        policy.disabledTools.insert("list_tables"); try store.save(policy)
        #expect(try !runtime.resourceTools().contains("list_tables"))
        do {
            _ = try await runtime.call("querycraft_execute_query", arguments: Data(#"{"connection_id":"invalid","sql":"SELECT 1"}"#.utf8))
            Issue.record("Missing connection must fail")
        } catch {
            let failure = try MCPHost.failure(error)
            let value = try JSONDecoder().decode(MCP.Value.self, from: failure.json)
            #expect(failure.code == "CONNECTION_NOT_FOUND")
            #expect(value.objectValue?["error"]?.objectValue?["automatic_retry"] == false)
        }
        policy.enabled = false; try store.save(policy)
        #expect(try runtime.resourceTools().isEmpty)
        #expect(try JSONDecoder().decode([Tool].self, from: await runtime.tools()).isEmpty)
        await runtime.shutdown()
    }
}
