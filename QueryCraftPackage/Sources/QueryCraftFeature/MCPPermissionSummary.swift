import Foundation

enum MCPPermissionSummary {
    static func access(_ profile: ConnectionProfile, policy: MCPPolicy) -> String {
        let copy = AppCopy.current
        guard policy.enabled else { return copy.text("MCP 已关闭", "MCP disabled") }
        guard policy.includesConnection(profile) else { return copy.text("禁止访问", "No access") }
        let rule = policy.connectionRule(profile)
        guard rule.allowedDatabases?.isEmpty != true else { return copy.text("对象范围禁止访问", "Object access denied") }
        if rule.scope == .selected, let names = rule.allowedDatabases {
            let modes = Set(names.map { policy.effectiveMode(profile, database: $0) })
            if modes.count == 1, let mode = modes.first { return mode.title }
            return copy.text("按对象分别限制", "Per-object limits")
        }
        let base = policy.effectiveMode(profile, database: nil)
        if rule.databaseModes.values.contains(where: { $0.rank < base.rank }) {
            return copy.text("\(base.title)，部分对象单独限制", "\(base.title), with object limits")
        }
        return base.title
    }

    static func objectKind(_ profile: ConnectionProfile) -> String {
        let copy = AppCopy.current
        return switch profile.databaseType {
        case .redis: copy.text("Redis DB", "Redis DBs")
        case .elasticsearch: copy.text("索引、别名或数据流", "Indices, aliases or data streams")
        case .kafka: "Topic"
        default: copy.text("数据库", "Databases")
        }
    }

    static func objectAccess(_ name: String, profile: ConnectionProfile, policy: MCPPolicy) -> String {
        guard policy.enabled, policy.includesConnection(profile),
              policy.connectionRule(profile).allowedDatabases?.contains(name) != false else {
            return AppCopy.current.text("禁止访问", "No access")
        }
        return policy.effectiveMode(profile, database: name).title
    }

    static func scope(_ profile: ConnectionProfile, policy: MCPPolicy) -> String {
        let rule = policy.connectionRule(profile), copy = AppCopy.current
        return switch rule.scope {
        case .all: copy.text("全部\(objectKind(profile))", "All \(objectKind(profile))")
        case .none: copy.text("禁止访问所有对象", "All objects denied")
        case .selected: rule.databases?.isEmpty == false
            ? (rule.databases ?? []).sorted().joined(separator: ", ")
            : copy.text("名单为空，禁止访问", "Empty selection; access denied")
        }
    }
}
