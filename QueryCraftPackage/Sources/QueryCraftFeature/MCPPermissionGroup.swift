import Foundation

struct MCPPermissionGroup: Identifiable {
    let groupID: UUID?
    let name: String
    let profiles: [ConnectionProfile]
    var sshProfiles: [SSHConnection] = []
    var id: String { groupID?.uuidString ?? "ungrouped" }
}
