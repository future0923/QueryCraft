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
        #expect(await destination.imports == 0)
    }

    @Test func disabledPolicyReadsNothingAndImportsNothing() async throws {
        let destination = ImportFixture()
        var policy = MCPPolicy(); policy.allConnections = true
        #expect(try await MCPCredentialAuthorization.authorize(profiles: [profile()], policy: policy,
            source: DeniedCredentialFixture(status: errSecInteractionNotAllowed), destination: destination) == 0)
        #expect(await destination.imports == 0)
    }
}
