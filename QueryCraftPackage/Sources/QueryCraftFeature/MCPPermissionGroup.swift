import Foundation

struct MCPPermissionGroup: Identifiable {
    let groupID: UUID?
    let name: String
    let profiles: [ConnectionProfile]
    var id: String { groupID?.uuidString ?? "ungrouped" }
}
