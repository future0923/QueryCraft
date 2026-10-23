import Foundation
import Testing
@testable import QueryCraftFeature

struct SSHAccessSyncTests {
    @MainActor @Test func bothEntrancesShareGrantsAndStaleEditorsCannotOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = SSHConnection(id: UUID(), name: "sync fixture", host: "localhost", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), privateKeyPath: "/fixture/key", storesCredential: false)
        let service = SSHConnectionService(directory: root, credentials: InMemoryCredentialStore())
        try await service.save(profile, original: nil, secret: nil, access: .connect)
        let store = MCPPolicyStore(directory: root)
        let initial = try store.load()
        let clean = SSHConnectionDraft(profile: profile, policy: initial)
        let dirty = SSHConnectionDraft(profile: profile, policy: initial); dirty.fileRead = true
        let before = SSHAccountAccess(id: profile.id, policy: initial)
        var changed = before; changed.access = .execute; changed.fileRead = true; changed.fileTransfer = true; changed.fileManagement = true
        try await service.updateAccess(profile, expecting: before, value: changed)
        await clean.synchronizeAccess(service: service)
        #expect(clean.access == .execute && clean.fileRead && clean.fileTransfer && clean.fileManagement)
        await dirty.synchronizeAccess(service: service)
        #expect(dirty.access == .connect && !dirty.fileTransfer)
        #expect(await dirty.save(service: service) == false)
        #expect(try SSHAccountAccess(id: profile.id, policy: store.load()) == changed)
        await #expect(throws: MCPFailure.self) { try await service.updateAccess(profile, expecting: before, value: before) }
        var staleMCP = initial; staleMCP.maximumRows = 123
        try store.savePreservingSSH(staleMCP)
        #expect(try SSHAccountAccess(id: profile.id, policy: store.load()) == changed)
        #expect(try store.load().maximumRows == 123)
        clean.fileTransfer = false
        #expect(await clean.save(service: service))
        let snapshot = try await service.snapshot()
        #expect(snapshot.policy.ssh?.fileTransferConnectionIDs.contains(profile.id) == false)
        #expect(snapshot.policy.ssh?.executionConnectionIDs.contains(profile.id) == true)
        #expect(try SSHConnectionStore(directory: root).load().count == 1)
    }
}
