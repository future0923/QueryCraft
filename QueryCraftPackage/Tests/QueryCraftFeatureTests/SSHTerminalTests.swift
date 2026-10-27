import Foundation
import Testing
@testable import QueryCraftFeature

@MainActor struct SSHTerminalTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "qc-terminal-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func profile(name: String = "fixture", jump: UUID? = nil, password: Bool = false) -> SSHConnection {
        SSHConnection(id: UUID(), name: name, host: "192.0.2.33", port: 22, username: "fixture",
            hostFingerprint: "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            privateKeyPath: password ? nil : "/fixture/key", storesCredential: password, jumpConnectionID: jump)
    }
    @Test func missingRendererFailsBeforeReadingCredentialsAndSurfacesAreLazy() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = profile(password: true), credentials = TerminalCountingCredentials()
        try SSHConnectionStore(directory: root).insert(saved)
        let session = SSHTerminalSession(profile: saved)
        #expect(session.surface == nil)
        session.start(service: SSHConnectionService(directory: root, credentials: credentials))
        for _ in 0..<100 where session.state == .connecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.state == .failed && session.surface == nil && !session.message.isEmpty)
        #expect(await credentials.readCount == 0)
        #expect(try SSHConnectionStore(directory: root).load() == [saved])
    }
    @Test func manualTerminalUsesSavedRoutesWithoutEnablingMCP() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let jump = profile(name: "jump"), target = profile(jump: jump.id)
        let store = SSHConnectionStore(directory: root); try store.insert(jump); try store.insert(target)
        let service = SSHConnectionService(directory: root)
        let request = try await service.terminalRequest(id: target.id)
        #expect(request.command == nil && !request.scanHostKey)
        #expect(request.connection == target && request.jumps.map(\.connection) == [jump])
        #expect(try MCPPolicyStore(directory: root).load().enabled == false)
        try store.remove(id: target.id)
        do { _ = try await service.terminalRequest(id: target.id); Issue.record("removed account was accepted") }
        catch { #expect(MCPFailure.normalized(error).code == .connectionNotFound) }
    }
    @Test func credentialSuspensionCannotConnectWithChangedAccount() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = profile(password: true), credentials = TerminalGatedCredentials()
        let store = SSHConnectionStore(directory: root); try store.insert(original)
        let service = SSHConnectionService(directory: root, credentials: credentials)
        let request = Task { try await service.terminalRequest(id: original.id) }
        await credentials.waitUntilRead()
        var updated = original; updated.host = "192.0.2.34"
        try store.replace(updated, expecting: original)
        await credentials.release()
        do { _ = try await request.value; Issue.record("changed account was accepted") }
        catch { #expect(MCPFailure.normalized(error).code == .sessionBusy) }
    }
    @Test func routeChangesDisconnectExistingTerminalAndRefreshKeepsOtherTabs() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let jump = profile(name: "jump"), target = profile(jump: jump.id), unrelated = profile(name: "other")
        let store = SSHConnectionStore(directory: root); try store.insert(jump); try store.insert(target); try store.insert(unrelated)
        let model = SSHTerminalWorkspace(service: SSHConnectionService(directory: root))
        let first = SSHTerminalSession(profile: target), second = SSHTerminalSession(profile: unrelated)
        first.state = .connected; first.endpoints = [jump, target]; second.state = .connected; second.endpoints = [unrelated]
        model.sessions = [first, second]; model.selection = first.id
        var changed = jump; changed.host = "192.0.2.44"; try store.replace(changed, expecting: jump)
        await model.reload()
        #expect(first.state == .disconnecting && second.state == .connected)
        #expect(model.sessions.count == 2 && model.selection == first.id)
        second.state = .closed; model.close(second)
        #expect(model.current === first)
    }
    @Test func panePreferencesAreIndependentAndKeepSessionSelection() throws {
        let name = "qc-terminal-layout-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let model = SSHTerminalWorkspace(preferences: preferences)
        let first = SSHTerminalSession(profile: profile(name: "first"))
        let second = SSHTerminalSession(profile: profile(name: "second"))
        first.state = .connected; second.state = .closed
        model.sessions = [first, second]; model.selectSession(first.id)
        model.toggleSidebar(); model.toggleInspector()
        #expect(!model.showsSidebar && !model.showsInspector && model.current === first)
        model.selectServer(second.profile.id)
        #expect(model.current === second && model.selectedServer == second.profile.id)
        model.selectSession(first.id)
        #expect(model.selectedServer == first.profile.id)
        let next = SSHTerminalWorkspace(preferences: preferences)
        #expect(!next.showsSidebar && !next.showsInspector)
        model.toggleSidebar()
        #expect(model.showsSidebar && !model.showsInspector)
        #expect(model.current === first && first.state == .connected)
        model.selectServer(UUID())
        #expect(model.current == nil && model.sessions.count == 2)
    }
    @Test func explicitPaneToggleSupersedesDeferredNativeCallback() async {
        let name = "qc-terminal-callback-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let model = SSHTerminalWorkspace(preferences: preferences)
        model.sidebarVisibilityChanged(false); model.inspectorVisibilityChanged(false)
        model.setSidebarVisible(true); model.setInspectorVisible(true)
        await Task.yield()
        #expect(model.showsSidebar && model.showsInspector)
        model.sidebarVisibilityChanged(false); model.inspectorVisibilityChanged(false)
        for _ in 0..<10 where model.showsSidebar || model.showsInspector { await Task.yield() }
        #expect(!model.showsSidebar && !model.showsInspector)
    }
    @Test func sessionLimitAndSelectionAreStable() throws {
        let model = SSHTerminalWorkspace()
        let fixture = profile()
        model.sessions = (0..<12).map { _ in let session = SSHTerminalSession(profile: fixture); session.state = .closed; return session }
        model.selection = model.sessions[5].id
        model.connect(fixture)
        #expect(model.sessions.count == 12 && model.error != nil)
        let current = model.current!, next = model.sessions[6]
        model.close(current)
        #expect(model.current === next && model.sessions.count == 11)
    }
}

private actor TerminalGatedCredentials: CredentialStore {
    private var reading = false
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var valueWaiter: CheckedContinuation<String?, Never>?
    func password(for connectionID: UUID) async throws -> String? {
        reading = true; readWaiter?.resume(); readWaiter = nil
        return await withCheckedContinuation { valueWaiter = $0 }
    }
    func waitUntilRead() async {
        if !reading { await withCheckedContinuation { readWaiter = $0 } }
    }
    func release() { valueWaiter?.resume(returning: "fixture-secret"); valueWaiter = nil }
    func save(password: String, for connectionID: UUID) async throws {}
    func delete(for connectionID: UUID) async throws {}
}

private actor TerminalCountingCredentials: CredentialStore {
    var readCount = 0
    func password(for profileID: UUID) async throws -> String? { readCount += 1; return "fixture-secret" }
    func save(password: String, for profileID: UUID) async throws {}
    func delete(for profileID: UUID) async throws {}
}
