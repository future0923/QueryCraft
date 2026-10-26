import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor
struct MCPPermissionEditingTests {
    private func makeModel(type: DatabaseType = .mysql) -> MCPSettingsModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "qc-permission-editor-" + UUID().uuidString)
        let model = MCPSettingsModel(directory: root, skillHomeDirectory: root.appending(path: "Home"),
            clientRegistrar: MCPClientRegistration(home: root.appending(path: "Home"), environment: [:]),
            settingsLoader: { .init(policy: .init(), connections: .init(groups: [], profiles: [])) },
            runtimeChecker: { .init(installedVersion: nil, availableVersion: nil, httpRunning: false) })
        let first = ConnectionGroup(id: UUID(), name: "Production", sortIndex: 0, createdAt: Date())
        let second = ConnectionGroup(id: UUID(), name: "Development", sortIndex: 1, createdAt: Date())
        model.groups = [first, second]
        model.profiles = [profile(type: type, group: first.id), profile(type: type, group: first.id),
                          profile(type: type, group: second.id), profile(type: type, group: nil)]
        model.didLoad = true
        model.policy.enabled = true
        return model
    }
    private func profile(type: DatabaseType, group: UUID?) -> ConnectionProfile {
        .init(id: UUID(), name: "fixture", groupID: group, databaseType: type, host: "localhost", port: 1234,
              username: "fixture", defaultDatabase: "allowed", tlsMode: .disabled,
              storesCredential: false, createdAt: Date())
    }

    @Test(arguments: [("0.1.0", "0.1.1", true), ("0.1.1", "0.1.1", false),
                      ("0.1.2", "0.1.1", false), ("0.1.9", "0.1.10", true)])
    func runtimeUpdateNoticeUsesNewerAvailableVersion(_ fixture: (String, String, Bool)) {
        let model = makeModel()
        model.availableVersion = fixture.1
        #expect(!model.runtimeUpdateAvailable) // A fresh installation is not an upgrade.
        model.installedVersion = fixture.0
        #expect(model.runtimeUpdateAvailable == fixture.2)
        model.availableVersion = nil
        #expect(!model.runtimeUpdateAvailable) // An unfinished check must not advertise an upgrade.
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func groupDefaultsPreserveExplicitOverridesObjectScopesAndUnrelatedRules(_ type: DatabaseType) throws {
        let model = makeModel(type: type)
        let group = try #require(model.permissionGroups.first)
        let p = try #require(group.profiles.first)
        model.policy.connections[p.id.uuidString] = .init(databases: ["allowed"], mode: .dataWrite,
            databaseModes: ["allowed": .readOnly], databaseAccess: .selected)
        model.policy.disabledTools = ["remove_connection"]
        let originalRule = model.rule(for: p.id)
        model.setGroupSelection(.fullAccess, for: group)
        #expect(model.policy.includesConnection(p))
        #expect(model.policy.effectiveMode(p, database: "allowed") == .readOnly)
        #expect(model.rule(for: p.id) == originalRule)
        #expect(model.policy.disabledTools == ["remove_connection"])
        #expect(model.policy.effectiveMode(p, database: "allowed") == .readOnly)
        #expect(model.policy.effectiveMode(p, database: "other") == .dataWrite)
        model.setGroupSelection(.denied, for: group)
        #expect(model.policy.includesConnection(p) == false)
        #expect(model.rule(for: p.id) == originalRule)
    }

    @Test func removingOneMemberPreservesOtherGroupsFutureGrants() throws {
        let model = makeModel()
        let first = model.groups[0], second = model.groups[1]
        model.policy.groupIDs = [first.id, second.id]
        let removed = model.profiles[0], sibling = model.profiles[1]
        model.setConnectionSelection(.denied, for: removed)
        #expect(model.policy.includesConnection(removed) == false)
        #expect(model.policy.includesConnection(sibling))
        #expect(model.policy.groupIDs.contains(first.id) == false)
        #expect(model.policy.groupIDs.contains(second.id))
        #expect(model.policy.includesConnection(profile(type: .mysql, group: second.id)))
        #expect(model.policy.includesConnection(profile(type: .mysql, group: first.id)) == false)
    }

    @Test func revokingAGroupFromAllConnectionsKeepsOtherCurrentGrants() throws {
        let model = makeModel()
        model.policy.allConnections = true
        let originalRules = model.policy.connections
        let group = try #require(model.permissionGroups.first)
        model.setGroupSelection(.denied, for: group)
        #expect(model.policy.allConnections == false)
        #expect(group.profiles.allSatisfy { model.policy.includesConnection($0) == false })
        #expect(model.profiles.filter { $0.groupID != group.groupID }.allSatisfy { model.policy.includesConnection($0) })
        #expect(model.policy.connections == originalRules)
    }

    @Test func stoppingFutureGroupGrantsRetainsCurrentMembers() throws {
        let model = makeModel()
        let group = try #require(model.permissionGroups.first)
        model.setGroupSelection(.dataWrite, for: group)
        model.setGroupAutomaticGrant(false, for: group)
        #expect(group.profiles.allSatisfy { model.policy.includesConnection($0) })
        #expect(model.policy.includesConnection(profile(type: .mysql, group: group.groupID)) == false)
        #expect(model.groupSelection(group) == .custom)
        model.setGroupAutomaticGrant(true, for: group)
        #expect(model.policy.includesConnection(profile(type: .mysql, group: group.groupID)))
    }

    @Test(arguments: DatabaseType.allCases)
    func explicitConnectionAndObjectAccessOverridesGroupUntilCleared(_ type: DatabaseType) throws {
        let model = makeModel(type: type)
        let group = try #require(model.permissionGroups.first)
        let p = try #require(group.profiles.first)
        model.setGroupSelection(.readOnly, for: group)
        #expect(model.connectionSelection(p) == .inherited)
        #expect(model.policy.effectiveMode(p, database: "allowed") == .readOnly)
        model.setConnectionSelection(.fullAccess, for: p)
        #expect(model.policy.effectiveMode(p, database: "allowed") == .fullAccess)
        var draft = model.rule(for: p.id)
        draft.databaseAccess = .selected; draft.databases = ["allowed"]
        draft.databaseModes["allowed"] = .dataWrite
        model.applyObjectScope(draft, for: p.id)
        model.setGroupSelection(.dataWrite, for: group)
        #expect(model.connectionSelection(p) == .fullAccess)
        #expect(model.policy.effectiveMode(p, database: "allowed") == .dataWrite)
        model.setConnectionSelection(.readOnly, for: p)
        #expect(model.policy.effectiveMode(p, database: "allowed") == .dataWrite)
        draft.databaseModes.removeValue(forKey: "allowed")
        model.applyObjectScope(draft, for: p.id)
        #expect(model.policy.effectiveMode(p, database: "allowed") == .readOnly)
        model.setConnectionSelection(.inherited, for: p)
        #expect(model.policy.effectiveMode(p, database: "allowed") == .dataWrite)
    }

    @Test func directoryNavigationAndSummaryNeverMutateStoredPolicy() throws {
        let model = makeModel()
        model.policy.allConnections = true
        model.policy.groupModes[model.groups[0].id.uuidString] = .readOnly
        model.policy.connections[model.profiles[0].id.uuidString] = .init(databases: ["allowed"],
            databaseModes: ["allowed": .readOnly], databaseAccess: MCPDatabaseAccess.none)
        #expect(MCPPermissionSummary.objectAccess("allowed", profile: model.profiles[0], policy: model.policy)
            == MCPPermissionSelection.denied.title)
        let policy = model.policy
        for destination in MCPSettingsDestination.allCases {
            model.navigate(to: destination)
            for group in model.permissionGroups { _ = model.groupSelection(group) }
            for profile in model.profiles {
                _ = model.connectionSelection(profile)
                _ = MCPPermissionSummary.access(profile, policy: model.policy)
                _ = MCPPermissionSummary.scope(profile, policy: model.policy)
            }
            #expect(model.policy == policy)
        }
        for page in ["access", "connections", "tools", "execution", "tuning", "activity"] {
            model.selectSettingsPage(page)
            #expect(model.selectedSettingsPage == page)
            #expect(model.policy == policy)
        }
        #expect(MCPSettingsDestination.allCases.count == 35)
        #expect(model.transport == "stdio")
        #expect(model.showsHTTPSettings)
        model.navigate(to: .connectionSearch)
        #expect(model.connectionFilterVisible)
        model.navigate(to: .tools)
        #expect(model.authorizationStep == "tools")
        model.search = "no matching connection"
        model.selectedConnection = model.profiles[2].id
        model.navigate(to: .objects)
        #expect(model.authorizationStep == "connections")
        #expect(model.search.isEmpty)
        #expect(model.scopeEditorConnection?.id == model.profiles[2].id)
        #expect(model.settingsScrollTarget == model.profiles[2].id.uuidString)
        #expect(model.policy == policy)
        let restored = try JSONDecoder().decode(MCPPolicy.self, from: JSONEncoder().encode(model.policy))
        #expect(restored == policy)
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func manualObjectNamesRetainRulesAcrossAllScopeModes(_ type: DatabaseType) throws {
        let model = makeModel(type: type), p = model.profiles[0]
        model.policy.connectionIDs.insert(p.id)
        model.updateRule(for: p.id) {
            $0.databases = ["old"]
            $0.databaseModes = ["old": .readOnly]
            $0.databaseAccess = .selected
        }
        model.databaseNameDrafts[p.id] = "new, 中文库， NewCase, new"
        model.addDatabaseNames(for: p.id)
        #expect(model.rule(for: p.id).databases == ["old", "new", "中文库", "NewCase"])
        #expect(model.rule(for: p.id).databaseModes == ["old": .readOnly])
        model.databaseChoices[p.id] = ["discovered"]
        #expect(Set(model.objectNames(for: p.id)) == ["old", "new", "中文库", "NewCase", "discovered"])
        for scope in MCPDatabaseAccess.allCases {
            model.updateRule(for: p.id) { $0.databaseAccess = scope }
            #expect(model.rule(for: p.id).databases == ["old", "new", "中文库", "NewCase"])
            #expect(model.rule(for: p.id).databaseModes == ["old": .readOnly])
        }
        model.updateRule(for: p.id) { $0.databaseAccess = .selected; $0.databases = [] }
        #expect(throws: MCPFailure.self) { try model.policy.authorize(tool: "list_databases", profile: p) }
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func scopeDraftAppliesOnlyObjectRulesWithoutGrantingConnection(_ type: DatabaseType) {
        let model = makeModel(type: type), profile = model.profiles[0]
        model.updateRule(for: profile.id) { $0.mode = .readOnly; $0.databases = ["old"] }
        let original = model.policy
        var draft = model.rule(for: profile.id)
        draft.databaseAccess = .selected
        draft.databases = ["new"]
        draft.databaseModes = ["new": .readOnly]
        draft.mode = .fullAccess // A stale sheet must never restore a connection-level mode.
        #expect(model.policy == original)
        model.applyObjectScope(draft, for: profile.id)
        #expect(!model.policy.includesConnection(profile))
        #expect(model.rule(for: profile.id).mode == .readOnly)
        #expect(model.rule(for: profile.id).scope == .selected)
        #expect(model.rule(for: profile.id).databases == ["new"])
        #expect(model.rule(for: profile.id).databaseModes == ["new": .readOnly])
        let applied = model.policy
        model.profiles.removeAll { $0.id == profile.id }
        model.applyObjectScope(.init(databaseAccess: .all), for: profile.id)
        #expect(model.policy == applied)
    }

    @Test func ungroupedGrantAndRevokeAllRetainConnectionConfiguration() throws {
        let model = makeModel()
        let group = try #require(model.permissionGroups.first(where: { $0.groupID == nil }))
        let p = try #require(group.profiles.first)
        model.updateRule(for: p.id) { $0.databases = ["allowed"]; $0.databaseAccess = .selected }
        model.setGroupSelection(.dataWrite, for: group)
        let rule = model.rule(for: p.id)
        #expect(model.groupSelection(group) == .dataWrite)
        model.revokeAllConnectionGrants()
        #expect(model.policy.includesConnection(p) == false)
        #expect(model.rule(for: p.id) == rule)
    }
}
