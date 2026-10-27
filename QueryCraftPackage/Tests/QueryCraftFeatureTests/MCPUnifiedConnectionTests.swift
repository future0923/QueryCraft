import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor struct MCPUnifiedConnectionTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "qc-unified-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func server(groupID: UUID? = nil) -> SSHConnection {
        SSHConnection(id: UUID(), name: "Linux fixture", host: "192.0.2.10", port: 22, username: "test",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: "/fixture/key", storesCredential: false, groupID: groupID)
    }
    private func model(_ root: URL, policy: MCPPolicy, servers: [SSHConnection], groups: [ConnectionGroup] = []) -> MCPSettingsModel {
        let value = MCPSettingsModel(directory: root, skillHomeDirectory: root.appending(path: "Home"),
            clientRegistrar: MCPClientRegistration(home: root.appending(path: "Home"), environment: [:]),
            settingsLoader: { .init(policy: policy, connections: .init(groups: groups, profiles: []), sshProfiles: servers) },
            runtimeChecker: { .init(installedVersion: nil, availableVersion: nil, httpRunning: false) })
        value.didLoad = true; value.policy = policy; value.sshProfiles = servers
        value.originalSSHPolicy = policy.ssh; value.groups = groups
        return value
    }

    @Test func draftSaveSharesOneTransactionAndPreservesUneditedExternalGrants() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = server(), second = server(), store = MCPPolicyStore(directory: root)
        try SSHConnectionStore(directory: root).insert(first); try SSHConnectionStore(directory: root).insert(second)
        var original = MCPPolicy(); original.enabled = true
        SSHAccess.connect.apply(id: first.id, to: &original)
        try store.save(original)
        let model = model(root, policy: original, servers: [first, second])
        model.updateSSHAccess(for: first.id) { $0.access = .execute; $0.fileRead = true }
        #expect(try store.load() == original)
        try store.update { SSHAccess.connect.apply(id: second.id, to: &$0) }
        model.policy.maximumRows = 123
        try model.persistSettingsPolicy()
        let saved = try store.load()
        #expect(saved.maximumRows == 123)
        #expect(saved.ssh?.executionConnectionIDs == [first.id])
        #expect(saved.ssh?.fileReadConnectionIDs == [first.id])
        #expect(saved.ssh?.connectionIDs == [first.id, second.id])
        #expect(model.originalSSHPolicy == saved.ssh)
    }

    @Test func conflictOrChangedAccountPreventsTheWholeSave() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = server(), accounts = SSHConnectionStore(directory: root), store = MCPPolicyStore(directory: root)
        try accounts.insert(profile)
        var original = MCPPolicy(); SSHAccess.connect.apply(id: profile.id, to: &original); try store.save(original)
        let model = model(root, policy: original, servers: [profile])
        model.updateSSHAccess(for: profile.id) { $0.access = .execute }
        model.policy.maximumRows = 234
        try store.update { SSHAccess.denied.apply(id: profile.id, to: &$0) }
        let externallyRevoked = try store.load()
        #expect(throws: MCPFailure.self) { try model.persistSettingsPolicy() }
        #expect(try store.load() == externallyRevoked)
        try store.save(original)
        var changed = profile; changed.host = "192.0.2.11"; try accounts.replace(changed, expecting: profile)
        #expect(throws: MCPFailure.self) { try model.persistSettingsPolicy() }
        #expect(try store.load() == original)
    }

    @Test func recheckMergesUntouchedGrantsButKeepsEditedDraftForConflictDetection() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let first = server(), second = server()
        var original = MCPPolicy(); SSHAccess.connect.apply(id: first.id, to: &original)
        let model = model(root, policy: original, servers: [first, second])
        model.updateSSHAccess(for: first.id) { $0.access = .execute }
        var external = original; SSHAccess.denied.apply(id: first.id, to: &external); SSHAccess.connect.apply(id: second.id, to: &external)
        model.rebaseSSHProfiles(.init(policy: external, connections: .init(groups: [], profiles: []), sshProfiles: [first, second]))
        #expect(SSHAccess.current(id: first.id, policy: model.policy) == .execute)
        #expect(SSHAccess.current(id: second.id, policy: model.policy) == .connect)
        #expect(model.originalSSHPolicy?.connectionIDs == [first.id, second.id])
    }

    @Test func sameGroupsSearchAndBulkActionsIncludeSSHWithoutWideningOtherGrants() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let group = ConnectionGroup(id: UUID(), name: "Production", sortIndex: 0, createdAt: .now)
        let grouped = server(groupID: group.id), ungrouped = server()
        let model = model(root, policy: .init(), servers: [grouped, ungrouped], groups: [group])
        #expect(model.permissionGroups.count == 2)
        #expect(model.permissionGroups[0].sshProfiles == [grouped])
        model.search = "Production"
        model.allowSearchResultsReadOnly()
        #expect(model.policy.ssh?.connectionIDs == [grouped.id])
        #expect(model.policy.ssh?.fileReadConnectionIDs == [grouped.id])
        #expect(model.policy.ssh?.executionConnectionIDs.isEmpty == true)
        #expect(model.policy.ssh?.fileTransferConnectionIDs.isEmpty == true)
        model.revokeAllConnectionGrants()
        #expect(model.policy.ssh?.connectionIDs.isEmpty == true)
        #expect(model.policy.ssh?.fileReadConnectionIDs.isEmpty == true)
    }

    @Test func groupMetadataIsBackwardCompatibleAndSearchable() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = server(), store = SSHConnectionStore(directory: root)
        let encoder = JSONEncoder()
        let legacy = try encoder.encode(profile)
        let decoded = try JSONDecoder().decode(SSHConnection.self, from: legacy)
        #expect(decoded.groupID == nil && decoded.sortIndex == nil)
        try store.insert(profile)
        let group = ConnectionGroup(id: UUID(), name: "Staging", sortIndex: 0, createdAt: .now)
        try store.move(profile, to: group.id, beforeID: nil)
        let grouped = try #require(store.load().first)
        #expect(grouped.id == profile.id && grouped.groupID == group.id)
        let results = ConnectionProfilesSearchResults(groups: [group], profiles: [], searchText: "Staging", sshProfiles: [grouped])
        #expect(results.sshProfiles == [grouped] && results.groups == [group])
        let orphan = ConnectionProfilesSearchResults(groups: [], profiles: [], searchText: "Linux", sshProfiles: [grouped])
        #expect(orphan.showsUngrouped)
    }

    @Test func groupDeletionIncludesSSHAccountsAndCredentials() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let group = ConnectionGroup(id: UUID(), name: "Staging", sortIndex: 0, createdAt: .now)
        let profile = server(groupID: group.id)
        let credentials = InMemoryCredentialStore()
        let service = SSHConnectionService(directory: root, credentials: credentials)
        try await service.save(profile, original: nil, secret: nil, access: .connect, fileRead: true)
        let accounts = SSHSettingsModel(service: service)
        let repository = InMemoryConnectionProfileRepository(profiles: [], groups: [group])
        let welcome = WelcomeModel(repository: repository, credentialStore: credentials,
            connectionTester: InMemoryConnectionTester(), ssh: accounts)
        await welcome.loadProfiles()
        let request = try await welcome.deletionRequest(for: group)
        #expect(request.sshProfiles == [profile])
        try await welcome.delete(request)
        #expect(welcome.groups.isEmpty && accounts.profiles.isEmpty)
        #expect(try MCPPolicyStore(directory: root).load().ssh?.connectionIDs.isEmpty == true)
    }

    @Test func groupRemovalChecksExternalJumpDependenciesAndCanRestorePreparedRemoval() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = server()
        var child = server(); child.jumpConnectionID = parent.id
        let service = SSHConnectionService(directory: root, credentials: InMemoryCredentialStore())
        try await service.save(parent, original: nil, secret: nil, access: .connect)
        try await service.save(child, original: nil, secret: nil, access: .execute, fileRead: true)
        await #expect(throws: MCPFailure.self) { try await service.removeGroup([parent]) }
        #expect(try await service.snapshot().profiles.count == 2)
        let backup = try await service.removeGroup([parent, child])
        #expect(try await service.snapshot().profiles.isEmpty)
        try await service.restoreGroup(backup)
        let restored = try await service.snapshot()
        #expect(Set(restored.profiles.map(\.id)) == [parent.id, child.id])
        #expect(SSHAccess.current(id: child.id, policy: restored.policy) == .execute)
        #expect(restored.policy.ssh?.fileReadConnectionIDs == [child.id])
    }
}
