import Foundation

/// The App Store host links the MCP runtime and supplies it here. Keeping the
/// interface in Feature avoids a circular dependency and a second implementation
/// of the tool protocol, permissions or database operations.
public protocol MCPEmbeddedServiceHosting: Sendable {
    func start(directory: URL) async throws
    func stop() async throws
    func isRunning() async -> Bool
}

public enum MCPEmbeddedService {
    public static func install(_ host: any MCPEmbeddedServiceHosting) async {
        await MCPServiceManager.shared.setEmbeddedHost(host)
    }
}
