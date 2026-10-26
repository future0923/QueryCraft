import Foundation
import Security
import Testing
@testable import QueryCraftFeature

private actor ImportFixture: CredentialImporting {
    private var passwords: [UUID: String] = [:]
    private(set) var imports = 0
    func password(for id: UUID) -> String? { passwords[id] }
    func save(password: String, for id: UUID) { passwords[id] = password }
    func delete(for id: UUID) { passwords[id] = nil }
    func importIfAbsent(password: String, for id: UUID) {
        imports += 1
        if passwords[id] == nil { passwords[id] = password }
    }
}

private actor DeniedCredentialFixture: CredentialStore {
    let status: OSStatus
    init(status: OSStatus) { self.status = status }
    func password(for id: UUID) throws -> String? { throw KeychainError(status: status) }
    func save(password: String, for id: UUID) { Issue.record("Must not write source") }
    func delete(for id: UUID) { Issue.record("Must not delete source") }
}

private actor AuthorizationFailureFixture: CredentialImporting {
    enum Stage: CaseIterable, Sendable { case importing, verification, cleanup }
    let stage: Stage
    private(set) var deletions = 0
    init(stage: Stage) { self.stage = stage }
    func password(for id: UUID) throws -> String? {
        if stage == .verification { throw KeychainError(status: errSecInteractionNotAllowed) }
        return "fixture"
    }
    func save(password: String, for id: UUID) { Issue.record("Use insert-only import") }
    func importIfAbsent(password: String, for id: UUID) throws {
        if stage == .importing { throw KeychainError(status: errSecInteractionNotAllowed) }
    }
    func delete(for id: UUID) throws {
        deletions += 1
        throw KeychainError(status: errSecInteractionNotAllowed)
    }
}

private actor PartiallyAvailableCredentialFixture: CredentialStore {
    let passwords: [UUID: String]
    let denied: [UUID: OSStatus]
    init(passwords: [UUID: String], denied: [UUID: OSStatus]) {
        self.passwords = passwords; self.denied = denied
    }
    func password(for id: UUID) throws -> String? {
        if let status = denied[id] { throw KeychainError(status: status) }
        return passwords[id]
    }
    func save(password: String, for id: UUID) { Issue.record("Must not write source") }
    func delete(for id: UUID) { Issue.record("Must not delete source") }
}

struct MCPCredentialAuthorizationTests {
    private func profile(_ type: DatabaseType = .mysql, group: UUID? = nil, stores: Bool = true) -> ConnectionProfile {
        .init(id: UUID(), name: "fixture", groupID: group, databaseType: type,
              host: "localhost", port: 1234, username: "fixture", defaultDatabase: nil,
              tlsMode: .disabled, storesCredential: stores, createdAt: Date())
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func migratesOnlySelectedUsableCredentials(_ type: DatabaseType) async throws {
        let selected = profile(type), unselected = profile(type), denied = profile(type), noPassword = profile(type, stores: false)
        var policy = MCPPolicy(); policy.enabled = true
        policy.connectionIDs = [selected.id, denied.id, noPassword.id]
        policy.connections[denied.id.uuidString] = .init(databaseAccess: MCPDatabaseAccess.none)
        let source = InMemoryCredentialStore(passwords: [selected.id: "fixture", unselected.id: "private", denied.id: "denied"])
        let destination = ImportFixture()
        let count = try await MCPCredentialAuthorization.authorize(profiles: [selected, unselected, denied, noPassword],
            policy: policy, source: source, destination: destination)
        #expect(count == 1)
        #expect(await destination.imports == 1)
        #expect(await destination.password(for: selected.id) == "fixture")
        #expect(await destination.password(for: unselected.id) == nil)
        #expect(await destination.password(for: denied.id) == nil)
    }

    @Test func groupGrantsAndRepeatedAuthorizationPreserveNewerPasswords() async throws {
        let group = UUID(), selected = profile(group: nil), grouped = profile(group: group)
        var policy = MCPPolicy(); policy.enabled = true; policy.groupIDs = [group]; policy.connectionIDs = [selected.id]
        let source = InMemoryCredentialStore(passwords: [selected.id: "old", grouped.id: "grouped"])
        let destination = ImportFixture()
        await destination.save(password: "edited concurrently", for: selected.id)
        for _ in 0..<2 {
            #expect(try await MCPCredentialAuthorization.authorize(profiles: [selected, grouped], policy: policy,
                source: source, destination: destination) == 2)
        }
        #expect(await destination.password(for: selected.id) == "edited concurrently")
        #expect(await destination.password(for: grouped.id) == "grouped")
    }

    @Test func missingPasswordFailsBeforeAnyMigration() async throws {
        let valid = profile(), missing = profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let destination = ImportFixture()
        let error = await #expect(throws: MCPFailure.self) {
            try await MCPCredentialAuthorization.authorize(profiles: [valid, missing], policy: policy,
                source: InMemoryCredentialStore(passwords: [valid.id: "fixture"]), destination: destination)
        }
        #expect(error?.code == .credentialUnavailable)
        #expect(error?.message.contains(missing.name) == true)
        #expect(await destination.imports == 0)
    }

    @Test func legacyCopiesAreRemovedOnlyAfterAllPasswordsAreInTheVault() async throws {
        let first = profile(), second = profile(), excluded = profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.connectionIDs = [first.id, second.id]
        let legacy = InMemoryCredentialStore(passwords: [first.id: "first", second.id: "second", excluded.id: "private"])
        let destination = ImportFixture()
        #expect(try await MCPCredentialAuthorization.authorize(profiles: [first, second, excluded], policy: policy,
            source: legacy, destination: destination, legacy: legacy) == 2)
        #expect(try await legacy.password(for: first.id) == nil)
        #expect(try await legacy.password(for: second.id) == nil)
        #expect(try await legacy.password(for: excluded.id) == "private")
        #expect(await destination.password(for: first.id) == "first")
        #expect(await destination.password(for: second.id) == "second")
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled])
    func unavailableLegacyAccessFailsWithoutRetrying(_ status: OSStatus) async throws {
        let connection = profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let destination = ImportFixture()
        let error = await #expect(throws: MCPFailure.self) {
            try await MCPCredentialAuthorization.authorize(profiles: [connection], policy: policy,
                source: DeniedCredentialFixture(status: status), destination: destination)
        }
        #expect(error?.code == (status == errSecUserCanceled ? .credentialCancelled : .credentialDenied))
        if status != errSecUserCanceled {
            #expect(error?.message.contains(connection.name) == true)
            #expect(error?.message.contains(AppCopy.current.text("重新输入并保存密码", "re-enter and save the password")) == true)
        }
        #expect(await destination.imports == 0)
    }

    @Test(arguments: AuthorizationFailureFixture.Stage.allCases)
    fileprivate func reportsTheActualFailingStage(_ stage: AuthorizationFailureFixture.Stage) async throws {
        let connection = profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let fixture = AuthorizationFailureFixture(stage: stage)
        let error = await #expect(throws: MCPFailure.self) {
            try await MCPCredentialAuthorization.authorize(profiles: [connection], policy: policy,
                source: InMemoryCredentialStore(passwords: [connection.id: "private fixture password"]),
                destination: fixture, legacy: fixture)
        }
        let failure = try #require(error)
        #expect(failure.code == .credentialDenied)
        #expect(failure.message.contains(connection.name))
        #expect(!failure.message.contains("private fixture password"))
        let copy = AppCopy.current
        switch stage {
        case .importing:
            #expect(failure.message.contains(copy.text("写入共享钥匙串", "into the shared Keychain vault")))
        case .verification:
            #expect(failure.message.contains(copy.text("无法确认", "Cannot verify")))
        case .cleanup:
            #expect(failure.message.contains(copy.text("共享密码已保存", "The shared password is saved")))
        }
        #expect(await fixture.deletions == (stage == .cleanup ? 1 : 0))
    }

    @Test func disabledPolicyReadsNothingAndImportsNothing() async throws {
        let destination = ImportFixture()
        var policy = MCPPolicy(); policy.allConnections = true
        #expect(try await MCPCredentialAuthorization.authorize(profiles: [profile()], policy: policy,
            source: DeniedCredentialFixture(status: errSecInteractionNotAllowed), destination: destination) == 0)
        #expect(await destination.imports == 0)
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func unavailablePasswordsDoNotBlockOtherSelectedConnections(_ type: DatabaseType) async throws {
        let valid = profile(type), denied = profile(type), missing = profile(type), excluded = profile(type)
        var policy = MCPPolicy(); policy.enabled = true
        policy.connectionIDs = [valid.id, denied.id, missing.id]
        let source = PartiallyAvailableCredentialFixture(passwords: [valid.id: "valid", excluded.id: "private"],
            denied: [denied.id: errSecInteractionNotAllowed])
        let legacy = InMemoryCredentialStore(passwords: [valid.id: "valid", denied.id: "inaccessible", excluded.id: "private"])
        let destination = ImportFixture()
        let report = try await MCPCredentialAuthorization.authorizeAvailable(profiles: [denied, valid, missing, excluded],
            policy: policy, source: source, destination: destination, legacy: legacy)
        #expect(report.authorizedCount == 1)
        #expect(Set(report.unavailableProfiles.map(\.id)) == [denied.id, missing.id])
        #expect(await destination.password(for: valid.id) == "valid")
        #expect(await destination.password(for: denied.id) == nil)
        #expect(await destination.password(for: missing.id) == nil)
        #expect(await destination.password(for: excluded.id) == nil)
        #expect(try await legacy.password(for: valid.id) == nil)
        #expect(try await legacy.password(for: denied.id) == "inaccessible")
        #expect(try await legacy.password(for: excluded.id) == "private")
    }

    @Test func cancellingAvailableAuthorizationDoesNotImportTheEarlierSnapshot() async throws {
        let valid = profile(), cancelled = profile()
        var policy = MCPPolicy(); policy.enabled = true; policy.allConnections = true
        let source = PartiallyAvailableCredentialFixture(passwords: [valid.id: "valid"],
            denied: [cancelled.id: errSecUserCanceled])
        let destination = ImportFixture()
        let error = await #expect(throws: MCPFailure.self) {
            try await MCPCredentialAuthorization.authorizeAvailable(profiles: [valid, cancelled], policy: policy,
                source: source, destination: destination)
        }
        #expect(error?.code == .credentialCancelled)
        #expect(await destination.imports == 0)
    }
}
