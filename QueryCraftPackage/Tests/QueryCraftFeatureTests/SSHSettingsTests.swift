import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHSettingsTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "ssh-settings-" + UUID().uuidString) }
    private func profile() -> SSHConnection {
        SSHConnection(id: UUID(), name: "Server", host: "127.0.0.1", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            storesCredential: true)
    }
    @Test func accountSaveEditAndRemoveShareCredentialsWithMCP() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryCredentialStore(), transport = RecordingSSHTransport()
        let service = SSHConnectionService(directory: directory, credentials: credentials, transport: transport)
        let profile = profile()
        try await service.save(profile, original: nil, secret: "first-local-secret", access: .connect)
        var policy = try MCPPolicyStore(directory: directory).load()
        #expect(!policy.enabled)
        #expect(SSHAccess.current(id: profile.id, policy: policy) == .connect)
        #expect(try await credentials.password(for: profile.id) == "first-local-secret")
        var edited = profile; edited.name = "Renamed account"
        try await service.save(edited, original: profile, secret: nil, access: .execute)
        policy = try MCPPolicyStore(directory: directory).load()
        #expect(SSHAccess.current(id: profile.id, policy: policy) == .execute)
        #expect(!policy.enabled)
        policy.enabled = true; try MCPPolicyStore(directory: directory).save(policy)
        let runtime = MCPRuntime(directory: directory, credentials: credentials, sshTransport: transport)
        _ = try await runtime.call("querycraft_ssh_test_connection", arguments: ["connection_id": .string(profile.id.uuidString)])
        #expect(await transport.requests.first?.secret == "first-local-secret")
        try await service.remove(edited)
        #expect(try await service.snapshot().profiles.isEmpty)
        #expect(try await credentials.password(for: profile.id) == nil)
        #expect(SSHAccess.current(id: profile.id, policy: try MCPPolicyStore(directory: directory).load()) == .denied)
        await #expect(throws: MCPFailure.self) {
            _ = try await runtime.call("querycraft_ssh_test_connection", arguments: ["connection_id": .string(profile.id.uuidString)])
        }
        await runtime.shutdown()
    }
    @Test func staleAccountEditsCannotOverwriteNewCredentials() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryCredentialStore(), profile = profile()
        let service = SSHConnectionService(directory: directory, credentials: credentials)
        try await service.save(profile, original: nil, secret: "original", access: .connect)
        var edited = profile; edited.username = "other"
        try await service.save(edited, original: profile, secret: "new-secret", access: .connect)
        await #expect(throws: MCPFailure.self) { try await service.save(profile, original: profile, secret: "stale-secret", access: .execute) }
        #expect(try await credentials.password(for: profile.id) == "new-secret")
        #expect(try await service.snapshot().profiles == [edited])
    }
    @Test func failedGrantWriteRollsBackProfileAndCredential() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryCredentialStore(), profile = profile()
        let service = SSHConnectionService(directory: directory, credentials: credentials)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("malformed".utf8).write(to: directory.appending(path: "mcp-policy.json"))
        await #expect(throws: MCPFailure.self) { try await service.save(profile, original: nil, secret: "never-persist", access: .execute) }
        #expect(try SSHConnectionStore(directory: directory).load().isEmpty)
        #expect(try await credentials.password(for: profile.id) == nil)
        // Settings can repair malformed policy; a full save must not depend on decoding old bytes.
        try MCPPolicyStore(directory: directory).save(MCPPolicy())
    }
    @Test func switchingToUnencryptedKeyRemovesSavedPassword() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryCredentialStore(), profile = profile()
        let service = SSHConnectionService(directory: directory, credentials: credentials)
        try await service.save(profile, original: nil, secret: "old-password", access: .execute)
        var key = profile; key.privateKeyPath = "/fixture/id_ed25519"; key.storesCredential = false
        try await service.save(key, original: profile, secret: nil, access: .denied)
        #expect(try await credentials.password(for: profile.id) == nil)
        #expect(try await service.snapshot().profiles == [key])
        #expect(try MCPPolicyStore(directory: directory).load().ssh?.executionConnectionIDs.isEmpty == true)
    }
    @Test func settingsSavesPreserveSSHAndGrantChangesPreserveDatabaseRules() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPPolicyStore(directory: directory), id = UUID(), databaseID = UUID()
        var stale = MCPPolicy(); stale.connectionIDs = [databaseID]; try store.save(stale)
        try store.update { SSHAccess.execute.apply(id: id, to: &$0) }
        stale.maximumRows = 123; try store.savePreservingSSH(stale)
        let latest = try store.load()
        #expect(latest.maximumRows == 123 && latest.connectionIDs == [databaseID])
        #expect(latest.ssh?.executionConnectionIDs == [id])
        try store.update { SSHAccess.denied.apply(id: id, to: &$0) }
        #expect(try store.load().connectionIDs == [databaseID])
    }
    @MainActor @Test func editorRequiresVerifiedHostAndNeverExposesExistingSecret() async throws {
        let draft = SSHConnectionDraft()
        draft.name = "test"; draft.host = "localhost"; draft.username = "user"; draft.fingerprint = profile().hostFingerprint
        draft.secret = "local-secret"
        #expect(throws: MCPFailure.self) { try draft.profile() }
        draft.verifiedHost = true
        #expect(try draft.profile().storesCredential)
        let existing = SSHConnectionDraft(profile: profile())
        #expect(existing.secret.isEmpty && existing.retainsCredential)
        #expect(try existing.profile().id == existing.id)
        existing.authentication = .privateKey; existing.keyPath = "/different/key"; existing.keyHasPassphrase = true
        #expect(throws: MCPFailure.self) { try existing.profile() }
    }
    @Test func localTestSendsNoCommandAndDoesNotRequireMCPEnablement() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let transport = RecordingSSHTransport(), profile = profile()
        let service = SSHConnectionService(directory: directory, credentials: InMemoryCredentialStore(), transport: transport)
        try await service.test(profile, secret: "one-time-secret")
        let request = try #require(await transport.requests.first)
        #expect(request.command == nil && request.secret == "one-time-secret")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "mcp-policy.json").path))
    }
    @Test func revokingAccessDoesNotNeedToReadLockedCredentials() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = profile(), credentials = LockedSSHSettingsCredentials()
        try SSHConnectionStore(directory: directory).insert(profile)
        try MCPPolicyStore(directory: directory).update { SSHAccess.execute.apply(id: profile.id, to: &$0) }
        let service = SSHConnectionService(directory: directory, credentials: credentials)
        try await service.save(profile, original: profile, secret: nil, access: .denied)
        #expect(try MCPPolicyStore(directory: directory).load().ssh?.connectionIDs.isEmpty == true)
    }
    @MainActor @Test func failedLoadingKeepsPreviouslyLoadedProfiles() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryCredentialStore(), profile = profile()
        let service = SSHConnectionService(directory: directory, credentials: credentials)
        try await service.save(profile, original: nil, secret: "fixture", access: .connect)
        let model = SSHSettingsModel(service: service); await model.load()
        #expect(model.loaded && model.profiles == [profile])
        try Data("bad".utf8).write(to: directory.appending(path: "ssh-connections.json"))
        await model.load()
        #expect(model.loaded && model.profiles == [profile] && model.error != nil)
    }
}

private actor LockedSSHSettingsCredentials: CredentialStore {
    func password(for profileID: UUID) throws -> String? { throw MCPFailure("Keychain is locked") }
    func save(password: String, for profileID: UUID) throws { throw MCPFailure("Keychain is locked") }
    func delete(for profileID: UUID) throws { throw MCPFailure("Keychain is locked") }
}
