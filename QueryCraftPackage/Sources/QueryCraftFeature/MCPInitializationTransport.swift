import Foundation
import Logging
import MCP

/// The pinned SDK decodes Client.Capabilities.experimental as [String: String],
/// although MCP permits arbitrary JSON values. Codex advertises codex/auth-change
/// as an object only for conversation connections, so settings discovery can
/// succeed while the actual conversation fails its initialize request.
///
/// QueryCraft does not implement experimental client capabilities. Ignore values
/// the SDK cannot represent, without changing supported capabilities, requests,
/// authentication, or the SDK's lifecycle/version negotiation. Remove this shim
/// when the SDK supports JSON-valued experimental capabilities.
actor MCPInitializationTransport: Transport, HTTPContextProviding {
    nonisolated let logger: Logger
    private let base: any Transport

    init(_ base: any Transport) async {
        self.base = base
        self.logger = await base.logger
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func send(_ data: Data) async throws { try await base.send(data) }

    func httpRequestContext(for id: ID) async -> HTTPRequest? {
        await (base as? any HTTPContextProviding)?.httpRequestContext(for: id)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            // AsyncThrowingStream bridges the SDK's stream. Its termination owns
            // cancellation of this forwarding task; the underlying transport
            // retains responsibility for framing, EOF and session shutdown.
            let task = Task { [base] in
                do {
                    for try await data in await base.receive() {
                        try Task.checkCancellation()
                        continuation.yield(Self.compatibleInitialization(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func compatibleInitialization(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["jsonrpc"] as? String == "2.0", request["method"] as? String == "initialize",
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any] else { return data }
        let supported = experimental.filter { $0.value is String }
        guard supported.count != experimental.count else { return data }
        capabilities["experimental"] = supported
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])) ?? data
    }
}
