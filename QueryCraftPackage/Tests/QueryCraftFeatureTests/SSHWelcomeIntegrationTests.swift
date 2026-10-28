import AppKit
import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor struct SSHWelcomeIntegrationTests {
    private func databases(id: UUID = UUID()) -> [ConnectionProfile] {
        DatabaseType.allCases.enumerated().map { index, type in
            ConnectionProfile(id: index == 0 ? id : UUID(), name: type.rawValue, groupID: nil, databaseType: type,
                host: "192.0.2.1", port: 1234, username: "fixture", defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, sortIndex: index, createdAt: .now)
        }
    }
    private func server(id: UUID = UUID()) -> SSHConnection {
        SSHConnection(id: id, name: "Linux server", host: "192.0.2.33", port: 22, username: "admin",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: nil, storesCredential: true)
    }
    @Test func welcomeSharesAccountIDsCredentialsGrantsAndExternalEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "welcome-ssh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = server(), credentials = InMemoryCredentialStore(), db = databases()
        let service = SSHConnectionService(directory: root, credentials: credentials)
        try await service.save(saved, original: nil, secret: "fixture-password", access: .execute)
        let accounts = SSHSettingsModel(service: service)
        let repository = InMemoryConnectionProfileRepository(profiles: db)
        let welcome = WelcomeModel(repository: repository, credentialStore: credentials, connectionTester: InMemoryConnectionTester(), ssh: accounts)
        await welcome.loadProfiles()
        #expect(welcome.connectionCount == 7 && accounts.profiles == [saved])
        #expect(Set(welcome.profiles.map(\.databaseType)) == Set(DatabaseType.allCases))
        let draft = SSHConnectionDraft(profile: accounts.profiles[0], policy: accounts.policy)
        #expect(draft.secret.isEmpty)
        draft.name = "Edited on the home screen"
        #expect(await draft.save(service: service))
        await accounts.load()
        #expect(accounts.profiles[0].id == saved.id)
        #expect(try await credentials.password(for: saved.id) == "fixture-password")
        #expect(try MCPPolicyStore(directory: root).load().ssh?.executionConnectionIDs.contains(saved.id) == true)
        var external = accounts.profiles[0]; external.name = "Changed by another client"
        try SSHConnectionStore(directory: root).replace(external, expecting: accounts.profiles[0])
        await accounts.load()
        #expect(accounts.profiles == [external] && welcome.connectionCount == 7)
        await accounts.remove(external)
        #expect(accounts.error == nil && accounts.profiles.isEmpty && welcome.connectionCount == 6)
        #expect(try await credentials.password(for: saved.id) == nil)
        #expect(try MCPPolicyStore(directory: root).load().ssh?.connectionIDs.contains(saved.id) == false)
        #expect(try await repository.fetchAll().count == 6)
    }
    @Test func outlineKeepsNativeSSHIdentityAndRoutesEachConnectionType() throws {
        let id = UUID(), db = databases(id: id), ssh = server(id: id)
        var openedDB: UUID?, openedSSH: UUID?
        let view = ConnectionProfilesOutlineView(groups: [], profiles: db, sshProfiles: [ssh], openSSH: { openedSSH = $0.id },
            searchQuery: "", showsUngrouped: true, openProfile: { openedDB = $0.id }, createProfile: { _ in }, editProfile: { _ in }, duplicateProfile: { _ in }, deleteProfile: { _ in }, renameGroup: { _ in }, deleteGroup: { _ in }, moveProfile: { _, _, _ in }, moveGroup: { _, _ in })
        let coordinator = ConnectionProfilesOutlineCoordinator(), outline = NSOutlineView()
        coordinator.update(from: view)
        #expect(coordinator.outlineView(outline, numberOfChildrenOfItem: nil) == 1)
        let dbSection = coordinator.outlineView(outline, child: 0, ofItem: nil)
        let dbNode = try #require(coordinator.outlineView(outline, child: 0, ofItem: dbSection) as? ConnectionProfilesOutlineNode)
        let sshNode = try #require(coordinator.outlineView(outline, child: 6, ofItem: dbSection) as? ConnectionProfilesOutlineNode)
        #expect(dbNode.id != sshNode.id)
        #expect(coordinator.outlineView(outline, numberOfChildrenOfItem: dbSection) == 7)
        #expect(coordinator.outlineView(outline, heightOfRowByItem: sshNode) == 44)
        #expect(coordinator.outlineView(outline, pasteboardWriterForItem: sshNode) != nil)
        coordinator.activate(sshNode)
        #expect(openedSSH == ssh.id && openedDB == nil)
        coordinator.activate(dbNode)
        #expect(openedDB == db[0].id)
    }
    @Test func oneSearchFindsProtocolHostUsernameAndName() {
        let profile = server()
        for query in ["ssh", "192.0.2.33", "admin", "Linux", "  SSH  "] { #expect(SSHWelcomeSearch.filter([profile], query: query) == [profile]) }
        #expect(SSHWelcomeSearch.filter([profile], query: "missing").isEmpty)
    }
    @Test func creationKeepsSSHOutOfDatabaseTypesAndDrivers() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MCPComponentCatalog(identity: .development, environment: [:])
        let plugin = SSHPluginSettingsModel(manager: SSHPluginManager(directory: root, catalog: catalog))
        plugin.installed = "0.9.0"; plugin.checked = true
        let flow = NewConnectionFlowModel(driverManager: DatabaseDriverManager(registry: DatabaseDriverRegistry()), sshPlugin: plugin)
        flow.selectedDatabaseProduct = .defaultProduct(for: .mysql)
        flow.selectedConnection = .ssh
        #expect(flow.selectsSSH && flow.selectedItem == nil && !flow.isInstalling)
        await flow.continueWithSelection()
        #expect(flow.step == .configureSSH)
        flow.selectedConnection = .database(.defaultProduct(for: .kafka))
        #expect(!flow.selectsSSH && flow.selectedDatabaseType == .kafka)
        #expect(DatabaseType.allCases.count == 6)
        flow.searchText = "SSH"
        #expect(!flow.catalogLoaded && !flow.matchesSSH && flow.visibleItems.isEmpty)
        await flow.loadCatalog()
        #expect(flow.catalogLoaded && flow.matchesSSH)
        let disabled = NewConnectionFlowModel(allowsSSH: false); #expect(!disabled.matchesSSH)
    }
}
