import Foundation

extension MCPPolicy {
    func canonicalDatabaseName(_ name: String, profile: ConnectionProfile) -> String {
        if profile.databaseType == .redis, let index = RedisLogicalDatabase.index(from: name) { return String(index) }
        return name
    }

    func permitsDatabaseName(_ name: String, profile: ConnectionProfile) -> Bool {
        guard let allowed = connectionRule(profile).allowedDatabases else { return true }
        let target = canonicalDatabaseName(name, profile: profile)
        return allowed.contains { canonicalDatabaseName($0, profile: profile) == target }
    }

    func accessMetadata(_ profile: ConnectionProfile) -> MCPJSONValue {
        let rule = connectionRule(profile), allowed = rule.allowedDatabases
        var overrides: [String: MCPJSONValue] = [:]
        for name in rule.databaseModes.keys where permitsDatabaseName(name, profile: profile) {
            overrides[canonicalDatabaseName(name, profile: profile)] = .string(effectiveMode(profile, database: name).rawValue)
        }
        return .object(["default_mode": .string(effectiveMode(profile, database: nil).rawValue),
                        "scope": .string(rule.scope.rawValue),
                        "allowed_databases": allowed.map { .array(Set($0.map { canonicalDatabaseName($0, profile: profile) }).sorted().map(MCPJSONValue.string)) } ?? .null,
                        "object_modes": .object(overrides)])
    }

    func executionMode(_ profile: ConnectionProfile, database: String?, args: [String: MCPJSONValue]) throws -> MCPExecutionMode {
        if profile.databaseType == .kafka, let topic = args.string("topic") {
            guard permitsObject(topic, profile: profile) else { throw MCPFailure("Topic is outside the authorized scope.", code: .accessDenied) }
            return effectiveMode(profile, database: topic)
        }
        if profile.databaseType == .elasticsearch, let path = args.string("path"), let method = args.string("method").flatMap({ WorkspaceRequestMethod(rawValue: $0.uppercased()) }) {
            let rule = connectionRule(profile)
            let request = WorkspaceRequest(method: method, path: path, body: args.string("body").map { Data($0.utf8) })
            let base = effectiveMode(profile, database: nil)
            let differingModes = rule.databaseModes.values.contains { $0 != base }
            try MCPRequestAuthorization.validateScoped(request, allowed: rule.allowedDatabases,
                objectOverrides: differingModes && WorkspaceRequestClassifier.requiresWriteAccess(request))
            let batch = WorkspaceRequestClassifier.isNDJSON(path: path)
            var targets = try (batch ? MCPRequestAuthorization.bulkTargets(request) : MCPRequestAuthorization.names(path))
            if method == .put, URLComponents(string: path)?.path.split(separator: "/").count == 1,
               let body = request.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let aliases = object["aliases"] as? [String: Any] { targets += aliases.keys }
            let modes = targets.map { effectiveMode(profile, database: $0) }
            if modes.contains(.readOnly) { return .readOnly }
            if modes.contains(.dataWrite) { return .dataWrite }
            if !modes.isEmpty { return .fullAccess }
            return effectiveMode(profile, database: nil)
        }
        return effectiveMode(profile, database: database)
    }

    func permitsAllObjectWrites(_ profile: ConnectionProfile) -> Bool {
        connectionRule(profile).allowedDatabases == nil && effectiveMode(profile, database: nil) == .fullAccess
            && connectionRule(profile).databaseModes.values.allSatisfy { $0 == .fullAccess }
    }
}
