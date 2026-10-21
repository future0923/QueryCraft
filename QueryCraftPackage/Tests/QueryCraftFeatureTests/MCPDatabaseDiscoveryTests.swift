import Foundation
import Testing
@testable import QueryCraftFeature

private actor MCPDatabaseDiscoveryGate {
    private var continuations: [Int: CheckedContinuation<[String], any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var count = 0

    func discover() async throws -> [String] {
        let index = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            for (expected, waiter) in waiters where expected <= count { waiter.resume() }
            waiters.removeAll { $0.0 <= count }
        }
    }
    func started(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
    func finish(_ index: Int, names: [String], fail: Bool = false) {
        let continuation = continuations.removeValue(forKey: index)
        if fail { continuation?.resume(throwing: MCPFailure("old request failure")) }
        else { continuation?.resume(returning: names) }
    }
}

@MainActor
struct MCPDatabaseDiscoveryTests {
    private func profile(id: UUID = UUID(), host: String = "old.example") -> ConnectionProfile {
        .init(id: id, name: "fixture", groupID: nil, databaseType: .mysql, host: host, port: 3306,
              username: "fixture", defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test(arguments: [false, true])
    func expiredRequestCannotOverwriteNewConnectionOrStopItsLoading(_ oldFails: Bool) async {
        let gate = MCPDatabaseDiscoveryGate(), old = profile()
        let updated = profile(id: old.id, host: "new.example")
        let root = FileManager.default.temporaryDirectory.appending(path: "qc-discovery-" + UUID().uuidString)
        let model = MCPSettingsModel(directory: root, skillHomeDirectory: root.appending(path: "Home"),
            clientRegistrar: MCPClientRegistration(home: root.appending(path: "Home"), environment: [:]),
            settingsLoader: { .init(policy: .init(), connections: .init(groups: [], profiles: [updated])) },
            runtimeChecker: { .init(installedVersion: nil, availableVersion: nil, httpRunning: false) },
            databaseDiscoverer: { _ in try await gate.discover() })
        model.didLoad = true
        model.profiles = [old]
        model.databaseChoices[old.id] = ["old cached data"]
        model.updateRule(for: old.id) { $0.databases = ["user selection"] }
        let first = Task { await model.discoverDatabases(for: old.id) }
        await gate.started(1)
        #expect(model.databaseChoices[old.id] == ["old cached data"])
        await model.recheck()
        #expect(model.databaseChoices[old.id] == nil)
        #expect(model.rule(for: old.id).databases == ["user selection"])
        let second = Task { await model.discoverDatabases(for: updated.id) }
        await gate.started(2)
        await gate.finish(0, names: ["stale response"], fail: oldFails)
        await first.value
        #expect(model.loadingDatabaseChoices.contains(updated.id))
        #expect(model.databaseChoices[updated.id] == nil)
        #expect(model.databaseChoiceErrors[updated.id] == nil)
        await gate.finish(1, names: ["new response"])
        await second.value
        #expect(model.databaseChoices[updated.id] == ["new response"])
        #expect(model.loadingDatabaseChoices.contains(updated.id) == false)
    }

    @Test func cancelledRefreshRetainsChoicesAndEmptySuccessIsDistinct() async {
        let gate = MCPDatabaseDiscoveryGate(), p = profile()
        let root = FileManager.default.temporaryDirectory.appending(path: "qc-discovery-" + UUID().uuidString)
        let model = MCPSettingsModel(directory: root, skillHomeDirectory: root.appending(path: "Home"),
            runtimeChecker: { .init(installedVersion: nil, availableVersion: nil, httpRunning: false) },
            databaseDiscoverer: { _ in try await gate.discover() })
        model.profiles = [p]
        model.databaseChoices[p.id] = ["existing"]
        let first = Task { await model.discoverDatabases(for: p.id) }
        await gate.started(1)
        first.cancel()
        await gate.finish(0, names: ["cancelled response"])
        await first.value
        #expect(model.databaseChoices[p.id] == ["existing"])
        #expect(model.databaseChoiceErrors[p.id] == nil)
        #expect(model.loadingDatabaseChoices.isEmpty)
        let second = Task { await model.discoverDatabases(for: p.id) }
        await gate.started(2)
        await gate.finish(1, names: [], fail: true)
        await second.value
        #expect(model.databaseChoices[p.id] == ["existing"])
        #expect(model.databaseChoiceErrors[p.id] != nil)
        let retry = Task { await model.discoverDatabases(for: p.id) }
        await gate.started(3)
        await gate.finish(2, names: [])
        await retry.value
        #expect(model.databaseChoices[p.id] == [])
        #expect(model.databaseChoiceErrors[p.id] == nil)
    }
}
