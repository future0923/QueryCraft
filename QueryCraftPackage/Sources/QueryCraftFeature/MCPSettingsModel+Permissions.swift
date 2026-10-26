import Foundation

extension MCPSettingsModel {
    var permissionGroups: [MCPPermissionGroup] {
        let knownIDs = Set(groups.map(\.id))
        var result = groups.map { group in
            MCPPermissionGroup(groupID: group.id, name: group.name,
                               profiles: profiles.filter { $0.groupID == group.id })
        }
        let ungrouped = profiles.filter { profile in
            profile.groupID.map { !knownIDs.contains($0) } ?? true
        }
        if !ungrouped.isEmpty {
            result.append(.init(groupID: nil, name: AppCopy.current.text("未分组", "Ungrouped"), profiles: ungrouped))
        }
        return result
    }

    var visiblePermissionGroups: [MCPPermissionGroup] {
        guard !search.isEmpty else { return permissionGroups }
        let matches = Set(filteredProfiles.map(\.id))
        return permissionGroups.filter { group in
            group.name.localizedCaseInsensitiveContains(search) || group.profiles.contains { matches.contains($0.id) }
        }
    }

    func visibleProfiles(in group: MCPPermissionGroup) -> [ConnectionProfile] {
        guard !search.isEmpty, !group.name.localizedCaseInsensitiveContains(search) else { return group.profiles }
        let matches = Set(filteredProfiles.map(\.id))
        return group.profiles.filter { matches.contains($0.id) }
    }

    func groupSelection(_ group: MCPPermissionGroup) -> MCPPermissionSelection {
        if let id = group.groupID, policy.allConnections || policy.groupIDs.contains(id) {
            return .init(policy.groupModes[id.uuidString] ?? .readOnly)
        }
        let included = group.profiles.filter { policy.includesConnection($0) }
        guard !included.isEmpty else { return .denied }
        if group.groupID == nil, included.count == group.profiles.count {
            let modes = Set(included.map { policy.effectiveMode($0, database: nil) })
            if modes.count == 1, let mode = modes.first { return .init(mode) }
        }
        return .custom
    }

    func setGroupSelection(_ selection: MCPPermissionSelection, for group: MCPPermissionGroup) {
        var updated = policy
        defer { policy = updated }
        if selection == .denied {
            let members = Set(group.profiles.map(\.id))
            // Materialize an all-connections grant before excluding any members.
            if updated.allConnections {
                updated.connectionIDs.formUnion(profiles.filter { updated.includesConnection($0) }.map(\.id))
                updated.allConnections = false
            }
            if let id = group.groupID { updated.groupIDs.remove(id) }
            // Orphan group memberships can still carry an implicit grant.
            for id in Set(group.profiles.compactMap(\.groupID)) {
                let retained = profiles.filter { $0.groupID == id && updated.includesConnection($0) }.map(\.id)
                updated.connectionIDs.formUnion(retained)
                updated.groupIDs.remove(id)
            }
            updated.connectionIDs.subtract(members)
            return
        }
        guard let mode = selection.mode else { return }
        if let id = group.groupID {
            updated.groupModes[id.uuidString] = mode
            updated.groupIDs.insert(id)
        } else {
            for profile in group.profiles {
                updated.connectionIDs.insert(profile.id)
                var rule = updated.connectionRule(profile)
                rule.mode = mode
                updated.connections[profile.id.uuidString] = rule
            }
        }
        // More specific connection and object rules remain explicit overrides of this default.
    }

    func connectionSelection(_ profile: ConnectionProfile) -> MCPPermissionSelection {
        guard policy.includesConnection(profile) else { return .denied }
        return rule(for: profile.id).mode.map(MCPPermissionSelection.init) ?? .inherited
    }

    func setConnectionSelection(_ selection: MCPPermissionSelection, for profile: ConnectionProfile) {
        if selection == .denied { removeConnection(profile); return }
        guard selection == .inherited || selection.mode != nil else { return }
        var updated = policy
        updated.connectionIDs.insert(profile.id)
        var rule = updated.connectionRule(profile)
        rule.mode = selection.mode
        updated.connections[profile.id.uuidString] = rule
        policy = updated
    }

    func setGroupAutomaticGrant(_ granted: Bool, for group: MCPPermissionGroup) {
        guard let id = group.groupID, !policy.allConnections else { return }
        if granted { policy.groupIDs.insert(id) }
        else {
            let current = group.profiles.filter { policy.includesConnection($0) }.map(\.id)
            policy.connectionIDs.formUnion(current)
            policy.groupIDs.remove(id)
        }
    }

    func revokeAllConnectionGrants() {
        policy.allConnections = false
        policy.groupIDs = []
        policy.connectionIDs = []
    }

    func allowSearchResultsReadOnly() {
        for profile in permissionGroups.flatMap({ visibleProfiles(in: $0) }) where !policy.includesConnection(profile) {
            policy.connectionIDs.insert(profile.id)
            updateRule(for: profile.id) { $0.mode = .readOnly }
        }
    }

    func applyObjectScope(_ draft: MCPConnectionPolicy, for id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        updateRule(for: id) {
            $0.databaseAccess = draft.scope
            $0.databases = draft.databases
            $0.databaseModes = draft.databaseModes
        }
    }

    func addDatabaseNames(for id: UUID) {
        let names = Set((databaseNameDrafts[id] ?? "").split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !names.isEmpty else { return }
        updateRule(for: id) { $0.databases = ($0.databases ?? []).union(names) }
        databaseNameDrafts[id] = ""
    }

    func objectNames(for id: UUID) -> [String] {
        let names = Set(databaseChoices[id] ?? []).union(rule(for: id).databases ?? [])
        let search = databaseSearches[id] ?? ""
        return names.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }.sorted()
    }

    func showPermissionPage(_ step: String) {
        section = "permissions"
        authorizationStep = step
        settingsScrollTarget = nil
        settingsNavigationRevision += 1
    }

}
