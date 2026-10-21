import Foundation

/// One index for both the complete settings directory and its native navigation.
enum MCPSettingsDestination: String, CaseIterable, Identifiable {
    case enable, runtime, credentials, client, transport, registration, configuration
    case httpService, httpAddress, httpAccess, httpToken
    case skillDestination, skillInstallation, help
    case groups, connection, futureMembers, connectionSearch, allConnections
    case objects, objectScope, objectDiscovery, objectNames, objectModes, review
    case tools, queryTimeout, results, sessions, discovery, metadataCache, ceiling
    case historyRecording, history, historyDetails, historyActions

    var id: String { rawValue }
    var section: String {
        switch self {
        case .enable, .runtime, .credentials, .client, .transport, .registration, .configuration,
             .httpService, .httpAddress, .httpAccess, .httpToken, .skillDestination, .skillInstallation, .help: "access"
        case .historyRecording, .history, .historyDetails, .historyActions: "activity"
        default: "permissions"
        }
    }
    var title: String {
        let copy = AppCopy.current
        return switch self {
        case .enable: copy.text("启用 MCP", "Enable MCP")
        case .runtime: copy.text("MCP 安装、升级、修复与卸载", "MCP install, update, repair and uninstall")
        case .credentials: copy.text("已保存密码授权", "Saved credential authorization")
        case .client: copy.text("客户端选择", "Client selection")
        case .transport: copy.text("stdio / HTTP 连接方式", "stdio / HTTP transport")
        case .registration: copy.text("客户端一键添加、更新与移除", "Client registration, update and removal")
        case .configuration: copy.text("配置预览与复制", "Configuration preview and copy")
        case .httpService: copy.text("HTTP 启动、停止与重启", "HTTP start, stop and restart")
        case .httpAddress: copy.text("HTTP 主机、端口与路径", "HTTP host, port and path")
        case .httpAccess: copy.text("远程访问、Hosts 与 Origins", "Remote access, Hosts and Origins")
        case .httpToken: copy.text("访问令牌与轮换", "Access token and rotation")
        case .skillDestination: copy.text("Skill 安装位置、路径与状态", "Skill destination, path and status")
        case .skillInstallation: copy.text("Skill 安装、更新与卸载", "Skill install, update and uninstall")
        case .help: copy.text("接入步骤与使用帮助", "Setup and usage help")
        case .groups: copy.text("分组授权与权限级别", "Group authorization and access")
        case .connection: copy.text("单个连接授权与权限限制", "Individual connection grants and limits")
        case .futureMembers: copy.text("以后加入分组的连接自动授权", "Automatic grants for future group members")
        case .connectionSearch: copy.text("连接搜索、批量允许与撤销", "Connection search, bulk grant and revocation")
        case .allConnections: copy.text("全部连接（含以后新增）", "All connections, including future ones")
        case .objects: copy.text("数据库、Redis DB、索引与 Topic 范围", "Database, Redis DB, index and topic scope")
        case .objectScope: copy.text("对象范围：全部、指定与禁止", "Object scope: all, selected or denied")
        case .objectDiscovery: copy.text("对象列表搜索与从连接加载", "Object search and discovery")
        case .objectNames: copy.text("手动输入精确名称", "Manual exact object names")
        case .objectModes: copy.text("按数据库或对象单独限制权限", "Per-database or object limits")
        case .review: copy.text("保存前核对最终生效权限", "Review effective permissions before saving")
        case .tools: copy.text("工具开关与批量选择", "Tool switches and bulk selection")
        case .queryTimeout: copy.text("查询超时与全局设置继承", "Query timeout and inherited settings")
        case .results: copy.text("最大结果行数与字节上限", "Result row and byte limits")
        case .sessions: copy.text("会话空闲超时与最大会话数", "Session idle timeout and count")
        case .discovery: copy.text("工具发现：直接、按需、两者", "Tool discovery: direct, lazy or both")
        case .metadataCache: copy.text("结构缓存与空闲元数据连接", "Metadata cache and idle connections")
        case .ceiling: copy.text("全局权限上限（原规则保留）", "Global permission ceiling (existing rules retained)")
        case .historyRecording: copy.text("记录调用摘要开关", "Record call summaries")
        case .history: copy.text("最近调用：状态、时间与耗时", "Recent calls: status, time and duration")
        case .historyDetails: copy.text("调用详情、连接 ID、大小与错误码", "Call details, connection ID, size and error code")
        case .historyActions: copy.text("重新检查与清空记录", "Refresh and clear call history")
        }
    }
}
