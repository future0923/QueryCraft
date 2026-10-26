import Foundation

extension MCPRuntime {
    func addConnection(_ args: [String: MCPJSONValue], policy: MCPPolicy) async throws -> MCPJSONValue {
        guard let type = DatabaseType(rawValue: try args.requiredString("type")) else { throw MCPFailure("Unsupported database driver.") }
        let port = args.integer("port", default: 0)
        guard (1...65535).contains(port) else { throw MCPFailure("Invalid port.") }
        let secret = args.string("password")
        let username = args.string("username") ?? ""
        let defaultAuthentication = [.kafka, .elasticsearch].contains(type) && username.isEmpty && secret == nil
            ? DatabaseConnectionAuthenticationMethod.none : .usernamePassword
        guard let authentication = DatabaseConnectionAuthenticationMethod(rawValue: args.string("authentication") ?? defaultAuthentication.rawValue),
              let tls = ConnectionTLSMode(rawValue: args.string("tls_mode") ?? ConnectionTLSMode.verifyIdentity.rawValue) else {
            throw MCPFailure("Invalid authentication or TLS mode.")
        }
        guard authentication != .apiKey || type == .elasticsearch,
              authentication != .none || secret == nil,
              authentication != .usernamePassword || type == .redis || !username.isEmpty else {
            throw MCPFailure("Authentication does not match this driver or the supplied credentials.")
        }
        let mechanism = args.string("kafka_sasl_mechanism").flatMap(KafkaSASLMechanism.init(rawValue:))
        if args["kafka_sasl_mechanism"] != nil && (type != .kafka || authentication != .usernamePassword || mechanism == nil) {
            throw MCPFailure("Kafka SASL mechanism requires a Kafka username/password connection.")
        }
        let profile = ConnectionProfile(id: UUID(), name: try args.requiredString("name"), groupID: nil, databaseType: type,
            host: try args.requiredString("host"), port: port, username: username,
            authenticationMethod: authentication, kafkaSASLMechanism: mechanism,
            defaultDatabase: args.string("database"), tlsMode: tls, storesCredential: secret != nil, createdAt: Date())
        if let secret { try await credentials.save(password: secret, for: profile.id) }
        do { try await repository.insert(profile) }
        catch { try? await credentials.delete(for: profile.id); throw error }
        return .object(["connection_id": .string(profile.id.uuidString), "authorized": .bool(policy.allConnections)])
    }

    func mutateConnection(_ tool: String, profile: ConnectionProfile, args: [String: MCPJSONValue], policy: MCPPolicy) async throws -> MCPJSONValue {
        guard policy.effectiveMode(profile, database: nil) == .fullAccess else { throw MCPFailure("Connection changes require full access.", code: .accessDenied) }
        invalidateMetadata(for: profile.id)
        await discardIdleConnection(for: profile.id)
        if tool == "remove_connection" {
            guard args.flag("confirm_high_risk") else { throw MCPFailure("Removing a connection requires confirm_high_risk=true.", code: .confirmationRequired) }
            guard !sessions.values.contains(where: { $0.profile.id == profile.id && $0.busy }) else { throw MCPFailure("Connection has a busy MCP session.") }
            for entry in Array(sessions.values) where entry.profile.id == profile.id {
                sessions.removeValue(forKey: entry.id); await entry.connection.close()
            }
            // Delete credentials first: a Keychain failure must not leave an orphaned secret.
            try await credentials.delete(for: profile.id)
            try await repository.delete(id: profile.id)
            return .object(["removed": true])
        }
        let copy = ConnectionProfile(id: UUID(), name: try args.requiredString("name"), groupID: profile.groupID,
            databaseType: profile.databaseType, databaseProduct: profile.databaseProduct, host: profile.host, port: profile.port,
            username: profile.username, authenticationMethod: profile.authenticationMethod, kafkaSASLMechanism: profile.kafkaSASLMechanism,
            defaultDatabase: profile.defaultDatabase, tlsMode: profile.tlsMode, storesCredential: profile.storesCredential, createdAt: Date())
        if profile.storesCredential {
            guard let secret = try await credentials.password(for: profile.id) else { throw MCPFailure("Source credential is unavailable.", code: .credentialUnavailable) }
            try await credentials.save(password: secret, for: copy.id)
        }
        do { try await repository.insert(copy) } catch { try? await credentials.delete(for: copy.id); throw error }
        return .object(["connection_id": .string(copy.id.uuidString)])
    }
}
