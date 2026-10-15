import Foundation
import Testing
@testable import QueryCraftFeature

private actor MCPRuntimeCheckGate {
    private var result: CheckedContinuation<MCPSettingsRuntimeStatus, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    func check() async -> MCPSettingsRuntimeStatus {
        calls += 1
        return await withCheckedContinuation { continuation in
            result = continuation
            for waiter in started { waiter.resume() }
            started.removeAll()
        }
    }
    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func finish() {
        result?.resume(returning: .init(installedVersion: "fixture", availableVersion: "fixture", httpRunning: true))
        result = nil
    }
}

@MainActor
struct MCPSettingsLoadingTests {
    private func snapshot() -> MCPSettingsSnapshot {
        var policy = MCPPolicy(); policy.enabled = true; policy.maximumRows = 321
        return .init(policy: policy, connections: .init(groups: [], profiles: []))
    }
    private func model(settingsLoader: @escaping @Sendable () async throws -> MCPSettingsSnapshot,
                       runtimeChecker: @escaping @Sendable () async throws -> MCPSettingsRuntimeStatus) -> MCPSettingsModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "qc-settings-" + UUID().uuidString)
        return MCPSettingsModel(directory: root, skillHomeDirectory: root.appending(path: "Home"),
            clientRegistrar: MCPClientRegistration(home: root.appending(path: "Home"), environment: [:]),
            settingsLoader: settingsLoader, runtimeChecker: runtimeChecker)
    }

    @Test func slowRuntimeCheckDoesNotBlockSettingsOrLoseEditsOnNavigation() async throws {
        let gate = MCPRuntimeCheckGate(), snapshot = snapshot()
        let model = model(settingsLoader: { snapshot }, runtimeChecker: { await gate.check() })
        let firstEntry = Task { await model.activate() }
        await gate.waitUntilStarted()
        #expect(model.didLoad)
        #expect(model.isLoading == false)
        #expect(model.isBusy == false)
        #expect(model.isCheckingRuntime)
        #expect(model.runtimeStatusLoaded == false)
        #expect(model.policy.maximumRows == 321)
        // Editing is available while the installed runtime's signature/version check is suspended.
        model.policy.maximumRows = 654
        model.client = "Codex"; model.section = "permissions"
        firstEntry.cancel() // SwiftUI cancels the disappearing pane's .task.
        let secondEntry = Task { await model.activate() }
        await gate.finish()
        await firstEntry.value; await secondEntry.value
        #expect(await gate.calls == 1)
        #expect(model.policy.maximumRows == 654)
        #expect(model.client == "Codex")
        #expect(model.section == "permissions")
        #expect(model.installedVersion == "fixture")
        #expect(model.httpRunning)
        #expect(model.isCheckingRuntime == false)
        #expect(model.runtimeStatusLoaded)
        await model.activate()
        #expect(await gate.calls == 1)
    }

    @Test func runtimeCheckFailurePreservesLoadedSettingsAndCanBeRechecked() async {
        let snapshot = snapshot()
        let failure = MCPFailure("runtime fixture failure")
        let model = model(settingsLoader: { snapshot }, runtimeChecker: { throw failure })
        await model.activate()
        #expect(model.didLoad)
        #expect(model.isBusy == false)
        #expect(model.isCheckingRuntime == false)
        #expect(model.policy.maximumRows == 321)
        #expect(model.error == nil)
        #expect(model.runtimeError == failure.localizedDescription)
        model.policy.maximumRows = 654
        await model.recheck()
        #expect(model.policy.maximumRows == 654)
        #expect(model.runtimeError == failure.localizedDescription)
        #expect(model.isBusy == false)
    }

    @Test func failedInitialSettingsLoadLeavesRetryAvailable() async {
        let failure = MCPFailure("settings fixture failure")
        let model = model(settingsLoader: { throw failure },
                                     runtimeChecker: { Issue.record("Runtime should not be checked before settings load"); return .init(installedVersion: nil, availableVersion: nil, httpRunning: false) })
        await model.activate()
        #expect(model.didLoad == false)
        #expect(model.isLoading == false)
        #expect(model.isBusy == false)
        #expect(model.runtimeStatusLoaded == false)
        #expect(model.error == failure.localizedDescription)
        await model.activate()
        #expect(model.isLoading == false)
        #expect(model.isBusy == false)
    }

    @Test(arguments: [DatabaseType.mysql, .postgresql, .doris, .redis, .elasticsearch, .kafka])
    func recheckRefreshesConnectionsWithoutReplacingUnsavedPolicy(_ type: DatabaseType) async {
        let profile = ConnectionProfile(id: UUID(), name: "new connection", groupID: nil, databaseType: type,
            host: "localhost", port: 1234, username: "", defaultDatabase: nil, tlsMode: .disabled,
            storesCredential: false, createdAt: Date())
        let initial = snapshot()
        let next = MCPSettingsSnapshot(policy: initial.policy, connections: .init(groups: [], profiles: [profile]))
        let source = MCPSettingsSnapshotSequence(initial: initial, next: next)
        let model = model(settingsLoader: { await source.load() }, runtimeChecker: {
            .init(installedVersion: nil, availableVersion: nil, httpRunning: false)
        })
        await model.activate()
        #expect(model.profiles.isEmpty)
        model.policy.maximumRows = 654
        await model.recheck()
        #expect(model.profiles.map(\.id) == [profile.id])
        #expect(model.policy.maximumRows == 654)
    }
}

private actor MCPSettingsSnapshotSequence {
    let initial: MCPSettingsSnapshot
    let next: MCPSettingsSnapshot
    private var first = true
    init(initial: MCPSettingsSnapshot, next: MCPSettingsSnapshot) { self.initial = initial; self.next = next }
    func load() -> MCPSettingsSnapshot {
        defer { first = false }
        return first ? initial : next
    }
}
