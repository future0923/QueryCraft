import Foundation
import QueryCraftFeature

/// App Store builds serve the same MCP protocol inside the sandboxed host.
/// No downloaded executable, launch agent or separate credential vault is used.
public actor QueryCraftMCPEmbeddedService: MCPEmbeddedServiceHosting {
    private var listener: MCPHTTPListener.Running?
    private var starting = false
    private var generation = 0
    public init() {}

    public func isRunning() -> Bool { listener?.channel.isActive == true }

    public func start(directory: URL) async throws {
        guard listener == nil, !starting else { return }
        starting = true
        let current = generation
        defer { starting = false }
        let server = try await MCPHTTPListener.start(directory: directory)
        guard current == generation, !Task.isCancelled else {
            try await server.stop()
            throw CancellationError()
        }
        listener = server
    }

    public func stop() async throws {
        generation += 1
        let previous = listener
        listener = nil
        try await previous?.stop()
    }
}
