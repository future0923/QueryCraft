import Foundation

/// Shared by native account testing and MCP. Passwords stay out of saved routes;
/// each hop obtains its own credential only for the lifetime of this request.
enum SSHRouteRequest {
    static func agentSocket(_ profile: SSHConnection, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        guard profile.authenticationMethod == .agent else { return nil }
        guard let path = profile.agentSocketPath ?? environment["SSH_AUTH_SOCK"], path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < 104 else {
            throw MCPFailure("Local SSH agent socket is unavailable. Set its absolute socket path or SSH_AUTH_SOCK.", code: .credentialUnavailable)
        }
        return path
    }
    static func make(profile: SSHConnection, jumps: [SSHConnection], credentials: any CredentialStore,
                     secretOverride: String? = nil, command: String? = nil, timeoutMilliseconds: Int,
                     maximumOutputBytes: Int, scanHostKey: Bool = false) async throws -> SSHRequest {
        var endpoints: [SSHJumpRequest] = []
        for (index, jump) in jumps.enumerated() {
            try Task.checkCancellation()
            do {
                let secret = jump.storesCredential ? try await credentials.password(for: jump.id) : nil
                guard !jump.storesCredential || secret != nil else { throw MCPFailure("Saved jump-host credential is unavailable.", code: .credentialUnavailable) }
                endpoints.append(.init(connection: jump, secret: secret, agentSocket: try agentSocket(jump)))
            } catch { throw preparationFailure(error, profile: jump, index: index + 1, jumpCount: jumps.count) }
        }
        try Task.checkCancellation()
        do {
            let secret: String?
            if scanHostKey { secret = nil }
            else if let secretOverride { secret = secretOverride }
            else { secret = profile.storesCredential ? try await credentials.password(for: profile.id) : nil }
            guard scanHostKey || !profile.storesCredential || secret != nil else { throw MCPFailure("Saved SSH credential is unavailable.", code: .credentialUnavailable) }
            return .init(connection: profile, secret: secret, command: command, timeoutMilliseconds: timeoutMilliseconds,
                maximumOutputBytes: maximumOutputBytes, jumps: endpoints, agentSocket: scanHostKey ? nil : try agentSocket(profile), scanHostKey: scanHostKey)
        } catch { throw preparationFailure(error, profile: profile, index: jumps.count + 1, jumpCount: jumps.count) }
    }
    private static func preparationFailure(_ error: any Error, profile: SSHConnection, index: Int, jumpCount: Int) -> any Error {
        if error is CancellationError { return error }
        let failure = MCPFailure.normalized(error)
        guard let diagnostic = SSHDiagnostic(value: .object(["endpoint_index": .int(index), "jump_count": .int(jumpCount),
            "phase": "preparing", "connection_id": .string(profile.id.uuidString)])) else { return failure }
        return MCPFailure(failure.message + " " + diagnostic.message, code: failure.code, details: .object(["ssh": diagnostic.value]))
    }
}
