import Foundation
import Testing
@testable import QueryCraftMobileProof

@MainActor struct MobileConnectionGroupSyncTests {
    private func profile(name: String = "fixture", groupID: UUID? = nil, index: Int = 0) throws -> MobileConnectionProfile {
        let draft = MobileConnectionDraft()
        draft.name = name
        draft.host = "sync-test.invalid"
        var value = try draft.profile()
        value.groupID = groupID
        value.sortIndex = index
        return value
    }

    @Test func olderLibraryDecodesWithoutGroupsAndKeepsConnections() throws {
        let original = try profile()
        let data = try JSONEncoder().encode(MobileLibraryState(profiles: [original]))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "connectionGroups")
        var profiles = try #require(json["profiles"] as? [[String: Any]])
        profiles[0].removeValue(forKey: "groupID")
        profiles[0].removeValue(forKey: "sortIndex")
        json["profiles"] = profiles
        let decoded = try JSONDecoder().decode(MobileLibraryState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.profiles == [original])
        #expect(decoded.connectionGroups.isEmpty)
    }

    @Test func missingParentStaysVisibleThenMovesIntoCorrectGroup() throws {
        let group = CloudSyncConnectionGroup(id: UUID(), name: "测试", sortIndex: 0, createdAt: .now)
        let child = try profile(groupID: group.id)
        var state = MobileLibraryState(profiles: [child])
        #expect(state.profiles(in: nil).map(\.id) == [child.id])
        state.connectionGroups = [group]
        #expect(state.profiles(in: nil).isEmpty)
        #expect(state.profiles(in: group.id).map(\.id) == [child.id])
        let restored = try JSONDecoder().decode(MobileLibraryState.self, from: JSONEncoder().encode(state))
        #expect(restored.connectionGroups == [group])
        #expect(restored.profiles(in: group.id) == [child])
    }

    @Test func groupsAndConnectionsFollowMacOrderAndEditingRetainsMembership() throws {
        let first = CloudSyncConnectionGroup(id: UUID(), name: "生产", sortIndex: 0, createdAt: .now)
        let last = CloudSyncConnectionGroup(id: UUID(), name: "开发", sortIndex: 1, createdAt: .now)
        let a = try profile(name: "server10", groupID: first.id, index: 1)
        let b = try profile(name: "server2", groupID: first.id, index: 1)
        let c = try profile(name: "server99", groupID: first.id, index: 0)
        let state = MobileLibraryState(profiles: [a, b, c], connectionGroups: [last, first])
        #expect(state.orderedConnectionGroups.map(\.id) == [first.id, last.id])
        #expect(state.profiles(in: first.id).map(\.id) == [c.id, b.id, a.id])
        let draft = MobileConnectionDraft(profile: a)
        draft.name = "edited"
        #expect(try draft.profile().groupID == first.id)
        #expect(try draft.profile().sortIndex == 1)
    }

    @Test func remoteGroupRenameAndDeletionPreserveConnectionsWithoutEcho() throws {
        let repo = GroupTestLibrary()
        let group = CloudSyncConnectionGroup(id: UUID(), name: "旧名称", sortIndex: 0, createdAt: .now)
        let child = try profile(groupID: group.id)
        repo.state = .init(profiles: [child], connectionGroups: [group])
        let model = MobileApplicationModel(repository: repo, passwords: GroupTestPasswords())
        var echoes = 0
        model.localChangesDidOccur = { _, _ in echoes += 1 }
        var renamed = group; renamed.name = "新名称"
        try model.applyCloudConnectionGroups([renamed], deletions: [])
        #expect(model.library.connectionGroups == [renamed])
        try model.applyCloudConnectionGroups([], deletions: [group.id])
        #expect(model.library.connectionGroups.isEmpty)
        #expect(model.library.profiles(in: nil).map(\.id) == [child.id])
        #expect(model.library.profiles.first?.groupID == nil)
        #expect(echoes == 0)
    }

    @Test(arguments: MobileDriver.allCases)
    func cloudConnectionsKeepMembershipForEverySupportedDriver(_ driver: MobileDriver) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try CloudSyncMetadataStore.standalone(at: root.appendingPathComponent("sync.sqlite"))
        let repo = GroupTestLibrary()
        let model = MobileApplicationModel(repository: repo, passwords: GroupTestPasswords())
        let group = CloudSyncConnectionGroup(id: UUID(), name: "同步分组", sortIndex: 3, createdAt: .now)
        let draft = MobileConnectionDraft(); draft.driver = driver; draft.name = "fixture"; draft.host = "sync-test.invalid"
        var remote = MobileCloudSyncStore.connection(from: try draft.profile(), secret: .none)
        remote.desktop = .init(groupID: group.id, sortIndex: 4, databaseProduct: driver.rawValue,
                               kafkaSASLMechanism: nil, createdAt: .now)
        let store = MobileCloudSyncStore(model: model, metadata: metadata)
        _ = try await store.apply([.upsert(.connectionGroup(group)), .upsert(.connection(remote))])
        let received = try #require(model.library.profiles.first)
        #expect(received.driver == driver)
        #expect(received.groupID == group.id)
        #expect(received.sortIndex == 4)
        #expect(model.library.profiles(in: group.id).map(\.id) == [remote.id])
        #expect(try metadata.outbox().isEmpty)
    }

    @Test func upgradeRefetchesOnceWithoutLosingUnsentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try CloudSyncMetadataStore.standalone(at: root.appendingPathComponent("sync.sqlite"))
        let key = CloudSyncKey(entity: .connection, id: UUID())
        try metadata.enqueue([key], deleted: false)
        try metadata.setState(Data([42]), for: CloudSyncMetadataStore.engineStateKey)
        try MobileCloudSync.prepareConnectionGroups(in: metadata)
        #expect(try metadata.state(CloudSyncMetadataStore.engineStateKey) == nil)
        #expect(try metadata.outbox().map(\.key) == [key])
        try metadata.setState(Data([43]), for: CloudSyncMetadataStore.engineStateKey)
        try MobileCloudSync.prepareConnectionGroups(in: metadata)
        #expect(try metadata.state(CloudSyncMetadataStore.engineStateKey) == Data([43]))
    }
}

@MainActor private final class GroupTestLibrary: MobileLibraryPersisting {
    var state = MobileLibraryState()
    func load() throws -> MobileLibraryState { state }
    func write(_ state: MobileLibraryState) throws { self.state = state }
}

@MainActor private final class GroupTestPasswords: MobilePasswordStoring {
    func password(for id: UUID) throws -> String? { nil }
    func setPassword(_ password: String?, for id: UUID) throws {}
}
