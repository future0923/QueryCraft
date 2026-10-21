import Foundation

/// Use the data directory so the independent runtime and desktop agree even
/// when both environments run the same downloaded MCP package.
enum MCPServerIdentity: Sendable {
    case production, development

    init(directory: URL) {
        self = directory.standardizedFileURL.lastPathComponent == "QueryCraftDev" ? .development : .production
    }
    var clientName: String { self == .development ? "querycraft-dev" : "querycraft" }
    var skillName: String { clientName }
    var runtimeAppName: String { self == .development ? "QueryCraft Dev MCP.app" : "QueryCraft MCP.app" }
    var displayName: String { self == .development ? "QueryCraft Dev" : "QueryCraft" }
}
