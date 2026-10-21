import Foundation
@_spi(MCP) import QueryCraftFeature
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1

actor MCPHTTPRouter {
    struct Entry {
        let transport: StatefulHTTPServerTransport
        let server: Server
        let runtime: MCPHostRuntime
        var lastUsed: Date
    }
    struct FixedID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
    let directory: URL
    let settings: MCPHTTPConfiguration
    private var pendingSessions = 0
    private var entries: [String: Entry] = [:]
    init(directory: URL, settings: MCPHTTPConfiguration) { self.directory = directory; self.settings = settings }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let configuration = try JSONDecoder().decode(MCPHTTPConfiguration.self, from: MCPHost.httpConfiguration(directory: directory))
            guard request.path == settings.path else { return .error(statusCode: 404, .invalidRequest("Not found")) }
            guard request.header("Authorization") == "Bearer \(configuration.token)" else {
                return .error(statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: ["WWW-Authenticate": "Bearer"])
            }
            guard let host = request.header("Host"), configuration.allowedHosts.contains(where: { host == $0 || host == "\($0):\(settings.port)" }) else {
                return .error(statusCode: 403, .invalidRequest("Host is not allowed"))
            }
            if let origin = request.header("Origin"), !configuration.allowedOrigins.contains(origin) {
                return .error(statusCode: 403, .invalidRequest("Origin is not allowed"))
            }
            let expired = entries.filter { Date().timeIntervalSince($0.value.lastUsed) > 1800 }.map(\.key)
            for id in expired { await remove(id) }
            if let id = request.header(HTTPHeaderName.sessionID) {
                guard let entry = entries[id] else { return .error(statusCode: 404, .invalidRequest("Session expired")) }
                entries[id]?.lastUsed = Date()
                let response = await entry.transport.handleRequest(request)
                if request.method == "DELETE", response.statusCode == 200 { await remove(id) }
                return response
            }
            guard request.method == "POST", let data = request.body,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["method"] as? String == "initialize" else {
                return .error(statusCode: 400, .invalidRequest("Initialize a session first"))
            }
            guard entries.count + pendingSessions < 32 else { return .error(statusCode: 503, .invalidRequest("Session capacity reached")) }
            pendingSessions += 1
            defer { pendingSessions -= 1 }
            let id = UUID().uuidString
            // Host, Origin and bearer auth are checked above on every request, including SSE and DELETE.
            let pipeline = StandardValidationPipeline(validators: [AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(), ProtocolVersionValidator()])
            let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedID(id: id), validationPipeline: pipeline)
            let runtime = MCPHostRuntime(directory: directory)
            let server = await QueryCraftMCPApplication.makeServer(runtime: runtime)
            try await server.start(transport: MCPInitializationTransport(transport))
            entries[id] = Entry(transport: transport, server: server, runtime: runtime, lastUsed: Date())
            let response = await transport.handleRequest(request)
            if response.statusCode >= 400 { await remove(id) }
            return response
        } catch { return .error(statusCode: 403, .invalidRequest("MCP is disabled or its policy is invalid")) }
    }
    private func remove(_ id: String) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        await entry.server.stop(); await entry.runtime.shutdown()
    }
    func shutdown() async { for id in Array(entries.keys) { await remove(id) } }
}

enum MCPHTTPListener {
    static func run(directory: URL) async throws {
        let configuration = try JSONDecoder().decode(MCPHTTPConfiguration.self, from: MCPHost.httpConfiguration(directory: directory))
        let router = MCPHTTPRouter(directory: directory, settings: configuration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        do {
            let server = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 32)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(MCPHTTPChannelHandler(router: router)) }
                    }
                }.bind(host: configuration.host, port: configuration.port).get()
            FileHandle.standardError.write(Data("QueryCraft MCP HTTP listening at \(configuration.endpoint)\n".utf8))
            try await server.closeFuture.get()
            await router.shutdown()
            try await group.shutdownGracefully()
        } catch {
            await router.shutdown(); try? await group.shutdownGracefully(); throw error
        }
    }
}

/// Mutable request state is confined to NIO's event loop. Async work captures only the
/// Sendable channel, immutable request, and actor router; no handler/context escapes.
private final class MCPHTTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    let router: MCPHTTPRouter
    private var head: HTTPRequestHead?
    private var body = Data()
    private var task: Task<Void, Never>?
    private var rejected = false
    init(router: MCPHTTPRouter) { self.router = router }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard task == nil else { context.close(promise: nil); return }
            self.head = head; body = Data(); rejected = false
        case .body(let buffer):
            guard body.count + buffer.readableBytes <= 1_048_576 else { rejected = true; context.close(promise: nil); return }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard !rejected, let head else { return }
            var headers: [String: String] = [:]
            for (key, value) in head.headers {
                let key = key.lowercased()
                guard headers[key] == nil else { context.close(promise: nil); return }
                headers[key] = value
            }
            let request = HTTPRequest(method: head.method.rawValue, headers: headers, body: body,
                                      path: String(head.uri.split(separator: "?", maxSplits: 1).first ?? ""))
            let channel = context.channel; let router = router
            task = Task {
                let response = await router.handle(request)
                do {
                    try await channel.eventLoop.submit {
                        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
                        headers.replaceOrAdd(name: "Connection", value: "close")
                        if let data = response.bodyData { headers.replaceOrAdd(name: "Content-Length", value: String(data.count)) }
                        else if case .stream = response { headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked") }
                        return channel.writeAndFlush(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: response.statusCode), headers: headers)))
                    }.flatMap { $0 }.get()
                    if case .stream(let stream, _) = response {
                        for try await data in stream {
                            try Task.checkCancellation()
                            try await write(data, to: channel)
                        }
                    } else if let data = response.bodyData { try await write(data, to: channel) }
                    try await channel.eventLoop.submit {
                        return channel.writeAndFlush(HTTPServerResponsePart.end(nil))
                    }.flatMap { $0 }.get()
                } catch { /* Disconnect ends the response stream; no retry of tool calls. */ }
                try? await channel.close()
            }
            self.head = nil; body = Data()
        }
    }
    func channelInactive(context: ChannelHandlerContext) { task?.cancel(); task = nil; context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { task?.cancel(); context.close(promise: nil) }
}

private func write(_ data: Data, to channel: any Channel) async throws {
    try await channel.eventLoop.submit {
        var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
        return channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
    }.flatMap { $0 }.get()
}

struct MCPHTTPConfiguration: Decodable, Sendable {
    let host: String
    let port: Int
    let path: String
    let allowedHosts: [String]
    let allowedOrigins: [String]
    let token: String
    var endpoint: String { "http://\(host.contains(":") ? "[\(host)]" : host):\(port)\(path)" }
}
