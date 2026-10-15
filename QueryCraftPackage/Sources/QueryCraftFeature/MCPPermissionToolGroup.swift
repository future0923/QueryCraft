import Foundation

enum MCPPermissionToolGroup: String, CaseIterable, Identifiable, Sendable {
    case schema, sessions, drivers, connections, desktop
    var id: Self { self }

    var title: String {
        let copy = AppCopy.current
        return switch self {
        case .schema: copy.text("结构与查询", "Schema and queries")
        case .sessions: copy.text("会话与事务", "Sessions and transactions")
        case .drivers: copy.text("Redis、Elasticsearch 与 Kafka", "Redis, Elasticsearch and Kafka")
        case .connections: copy.text("连接与驱动", "Connections and drivers")
        case .desktop: copy.text("桌面集成", "Desktop integration")
        }
    }

    var tools: [MCPToolDefinition] { Self.groupedTools[self] ?? [] }

    private static let groupedTools: [Self: [MCPToolDefinition]] = {
        let names: [Self: Set<String>] = [
            .schema: MCPToolCatalog.metadataTools.union(["execute_query", "execute_batch"]),
            .sessions: ["open_session", "close_session", "begin_transaction", "commit_transaction", "rollback_transaction"],
            .drivers: ["execute_redis_command", "execute_request", "peek_messages", "send_message", "consumer_groups"],
            .connections: ["list_connections", "add_connection", "duplicate_connection", "remove_connection", "plugin_list", "plugin_tools", "plugin_call"],
            .desktop: ["open_table", "execute_and_show"]
        ]
        return names.mapValues { group in MCPToolCatalog.definitions.filter { group.contains($0.name) } }
    }()
}
