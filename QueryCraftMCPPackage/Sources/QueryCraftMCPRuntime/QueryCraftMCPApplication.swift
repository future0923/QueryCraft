import Foundation
import MCP
@_spi(MCP) import QueryCraftFeature

public enum QueryCraftMCPApplication {
    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "QCMCPVersion") as? String ?? "0.1.0" }
    public static func run(arguments: [String]) async throws {
        if arguments == ["--self-test"] {
            try await MCPHost.selfTestParser()
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let runtime = MCPHostRuntime(directory: temporary)
            let server = await makeServer(runtime: runtime)
            let pair = await InMemoryTransport.createConnectedPair()
            try await server.start(transport: MCPInitializationTransport(pair.server))
            let client = Client(name: "QueryCraft Self Check", version: version)
            _ = try await client.connect(transport: pair.client)
            _ = try await client.listTools()
            await client.disconnect(); await server.stop(); await runtime.shutdown()
            print("MCP handshake OK")
            return
        }
        guard let configuration = try await MCPHost.prepare(arguments: arguments) else { return }
        if configuration.http { try await MCPHTTPListener.run(directory: configuration.directory) }
        else {
            let runtime = MCPHostRuntime(directory: configuration.directory)
            let server = await makeServer(runtime: runtime)
            try await server.start(transport: MCPInitializationTransport(StdioTransport()))
            await server.waitUntilCompleted()
            await runtime.shutdown()
        }
    }

    static func makeServer(runtime: MCPHostRuntime) async -> Server {
        await runtime.startMaintenance()
        let server = Server(name: runtime.displayName, version: version, instructions: MCPHost.instructions,
            capabilities: .init(resources: .init(), tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: try JSONDecoder().decode([Tool].self, from: await runtime.tools())) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let data = try await runtime.call(params.name, arguments: JSONEncoder().encode(params.arguments ?? [:]))
                let value = try JSONDecoder().decode(Value.self, from: data)
                let maximumBytes = (try? runtime.maximumResultBytes()) ?? 4 * 1024 * 1024
                guard data.count <= maximumBytes else { throw MCPError.invalidParams("Result exceeds the configured limit. Narrow the request.") }
                return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: Optional.some(value), isError: false)
            } catch {
                let failure = try MCPHost.failure(error)
                return .init(content: [.text(text: failure.text, annotations: nil, _meta: nil)],
                             structuredContent: Optional.some(try JSONDecoder().decode(Value.self, from: failure.json)), isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            let tools = try JSONDecoder().decode([Tool].self, from: await runtime.tools())
            return .init(resources: tools.contains(where: { $0.name == "querycraft_list_connections" })
                ? [.init(name: "connections", uri: "querycraft://connections", mimeType: "application/json")] : [])
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            let permitted = try runtime.resourceTools()
            let templates: [(String, String, String)] = [
                ("list_databases", "querycraft://connections/{connection_id}/databases", "databases"),
                ("list_tables", "querycraft://connections/{connection_id}/tables{?database,schema,refresh}", "tables"),
                ("describe_table", "querycraft://connections/{connection_id}/table-schema{?database,schema,table,refresh}", "table-schema")
            ]
            return .init(templates: templates.filter { permitted.contains($0.0) }.map {
                .init(uriTemplate: $0.1, name: $0.2, mimeType: "application/json")
            })
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard let url = URLComponents(string: params.uri), url.scheme == "querycraft", url.host == "connections" else {
                throw MCPError.invalidParams("Unknown resource URI")
            }
            let segments = url.path.split(separator: "/").map(String.init)
            var args: [String: Value] = [:]
            for item in url.queryItems ?? [] {
                guard ["database", "schema", "table", "refresh"].contains(item.name), args[item.name] == nil else { throw MCPError.invalidParams("Invalid resource arguments") }
                if item.name == "refresh" {
                    guard let value = item.value, ["true", "false"].contains(value) else { throw MCPError.invalidParams("refresh must be true or false") }
                    args[item.name] = .bool(value == "true")
                } else { args[item.name] = item.value.map(Value.string) }
            }
            let tool: String
            if segments.isEmpty { tool = "list_connections" }
            else {
                guard segments.count == 2, UUID(uuidString: segments[0]) != nil else { throw MCPError.invalidParams("Invalid connection resource") }
                args["connection_id"] = .string(segments[0])
                switch segments[1] {
                case "databases": tool = "list_databases"
                case "tables": tool = "list_tables"
                case "table-schema": tool = "describe_table"
                default: throw MCPError.invalidParams("Unknown resource")
                }
            }
            let data = try await runtime.call("querycraft_" + tool, arguments: JSONEncoder().encode(args))
            guard data.count <= (try runtime.maximumResultBytes()) else { throw MCPError.invalidParams("Resource exceeds result limit") }
            return .init(contents: [.text(String(decoding: data, as: UTF8.self), uri: params.uri, mimeType: "application/json")])
        }
        return server
    }
}
