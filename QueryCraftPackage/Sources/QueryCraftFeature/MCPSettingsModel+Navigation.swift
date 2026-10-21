import Foundation

extension MCPSettingsModel {
    var selectedSettingsPage: String {
        guard section == "permissions" else { return section }
        switch authorizationStep {
        case "objects": return "connections"
        case "overrides": return "ceiling"
        default: return authorizationStep
        }
    }

    func selectSettingsPage(_ page: String) {
        switch page {
        case "access", "activity": section = page
        case "connections", "tools", "execution", "tuning", "ceiling":
            section = "permissions"
            authorizationStep = page
        default: return
        }
        settingsScrollTarget = nil
        settingsNavigationRevision += 1
    }

    func navigate(to destination: MCPSettingsDestination) {
        section = destination.section
        if destination.section == "permissions" { authorizationStep = "connections" }
        switch destination {
        case .enable, .runtime, .credentials: settingsScrollTarget = "access-runtime"
        case .client, .transport, .registration, .configuration: settingsScrollTarget = "access-client"
        case .httpService, .httpAddress, .httpAccess, .httpToken:
            showsHTTPSettings = true
            settingsScrollTarget = "access-http"
        case .skillDestination, .skillInstallation: settingsScrollTarget = "access-skill"
        case .help: settingsScrollTarget = "access-help"
        case .allConnections:
            settingsScrollTarget = "permission-scope"
        case .tools: showPermissionPage("tools"); return
        case .queryTimeout, .results, .sessions: showPermissionPage("execution"); return
        case .discovery, .metadataCache: showPermissionPage("tuning"); return
        case .ceiling: showPermissionPage("ceiling"); return
        case .connection:
            search = ""
            settingsScrollTarget = profiles.first(where: { $0.id == selectedConnection })?.id.uuidString
                ?? profiles.first?.id.uuidString ?? "permission-connections"
        case .futureMembers:
            search = ""
            settingsScrollTarget = permissionGroups.first(where: { $0.groupID != nil }).map { "group-future-" + $0.id }
                ?? "permission-connections"
        case .connectionSearch:
            connectionFilterVisible = true
            settingsScrollTarget = "permission-connections"
        case .objects, .objectScope, .objectDiscovery, .objectNames, .objectModes:
            search = ""
            if let profile = profiles.first(where: { $0.id == selectedConnection }) ?? profiles.first,
               permissionGroups.contains(where: { $0.profiles.contains(where: { $0.id == profile.id }) }) {
                scopeEditorConnection = profile
                selectedConnection = profile.id
                settingsScrollTarget = profile.id.uuidString
            } else { settingsScrollTarget = "permission-connections" }
        case .groups:
            search = ""
            settingsScrollTarget = "permission-connections"
        default: settingsScrollTarget = "permission-connections"
        }
        settingsNavigationRevision += 1
    }
}
