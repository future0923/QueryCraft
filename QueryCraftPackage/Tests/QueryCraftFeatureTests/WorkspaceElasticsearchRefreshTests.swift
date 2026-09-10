import Foundation
import Testing
@testable import QueryCraftFeature

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor
struct WorkspaceElasticsearchRefreshTests {
    @Test func consoleMutationRefreshesEachDocumentPageOnce() async throws {
        let profile = ConnectionProfile(id: UUID(), name: "Elasticsearch", groupID: nil,
            databaseProduct: .elasticsearch, host: "127.0.0.1", port: 9200,
            username: "elastic", defaultDatabase: nil, tlsMode: .disabled,
            storesCredential: false, createdAt: .now)
        let first = WorkspaceDatabaseObjectSelection(databaseName: "Elasticsearch", objectName: "first", kind: .elasticsearchIndex)
        let second = WorkspaceDatabaseObjectSelection(databaseName: "Elasticsearch", objectName: "second", kind: .elasticsearchIndex)
        let page = WorkspaceDatabaseDataPage(columns: [.init(id: 0, name: "name")],
            rows: [.init(id: 0, values: [.text("one")]), .init(id: 1, values: [.text("two")])],
            offset: 0, limit: 2, hasNextPage: false)
        let model = WorkspaceModel(profileID: profile.id,
            repository: InMemoryConnectionProfileRepository(profiles: [profile]),
            credentialStore: InMemoryCredentialStore(),
            sessionFactory: InMemoryWorkspaceSessionFactory(databases: ["Elasticsearch"],
                objectsByDatabase: ["Elasticsearch": [first.object, second.object]],
                dataByObject: [first: page, second: page]))
        _ = await model.connect()
        await model.selectObject(second)
        await model.loadData(for: second, offset: 0, limit: 1)
        let secondBefore = try #require(model.selectedObjectDataState.page).rowStore
        await model.selectObject(first)
        await model.loadData(for: first, offset: 0, limit: 1)
        let before = try #require(model.selectedObjectDataState.page).rowStore

        await model.didMutateElasticsearchMapping()
        await model.loadData(for: first, offset: 0, limit: 1)
        let refreshed = try #require(model.selectedObjectDataState.page).rowStore
        #expect(refreshed !== before)
        await model.loadData(for: first, offset: 0, limit: 1)
        #expect(model.selectedObjectDataState.page?.rowStore === refreshed)
        await model.loadData(for: first, offset: 1, limit: 1)
        #expect(model.selectedObjectDataState.page?.offset == 1)
        #expect(model.selectedObjectDataState.page?.rows.first?.values == [.text("two")])

        await model.selectObject(second)
        await model.loadData(for: second, offset: 0, limit: 1)
        #expect(model.selectedObjectDataState.page?.rowStore !== secondBefore)
        let secondRefreshed = try #require(model.selectedObjectDataState.page).rowStore
        await model.loadData(for: second, offset: 0, limit: 1)
        #expect(model.selectedObjectDataState.page?.rowStore === secondRefreshed)
        await model.loadData(for: second, offset: 0, limit: 1, force: true)
        #expect(model.selectedObjectDataState.page?.rowStore !== secondRefreshed)
        await model.disconnect()
    }

    @Test func newerServerRevisionSupersedesSameDocumentReadWithoutHidingContent() async throws {
        let model = WorkspaceElasticsearchDocumentInspectorModel()
        let reference = WorkspaceDocumentReference(index: "logs", id: "same", routing: "tenant")
        let first = snapshot(reference, version: 1)
        await model.load(reference: reference) { _ in first }
        let gate = DocumentReadGate()
        let previousRead = Task { await model.load(reference: reference, serverRevision: 1) { _ in await gate.read() } }
        while gate.continuation == nil { await Task.yield() }
        #expect(model.loadedSnapshot == first)
        #expect(model.isLoading)
        #expect(!model.canBeginEditing)
        #expect(throws: WorkspaceDocumentEditingError.unavailable) { try model.beginEditing() }
        let latest = snapshot(reference, version: 3)
        await model.load(reference: reference, serverRevision: 2) { _ in latest }
        gate.continuation?.resume(returning: snapshot(reference, version: 2))
        gate.continuation = nil
        await previousRead.value
        #expect(model.loadedSnapshot == latest)
        #expect(!model.isLoading)
        #expect(model.canBeginEditing)

        try model.beginEditing()
        model.draftText = #"{"local":"draft"}"#
        await model.load(reference: reference, serverRevision: 3) { _ in
            Issue.record("A server mutation must not replace the JSON draft")
            return first
        }
        #expect(model.draftText == #"{"local":"draft"}"#)
        #expect(model.loadedSnapshot == latest)
        model.discardChanges()
    }

    private func snapshot(_ reference: WorkspaceDocumentReference, version: Int) -> WorkspaceDocumentSnapshot {
        .init(reference: reference, version: version, sequenceNumber: Int64(version), primaryTerm: 1,
              score: nil, sourceJSON: Data("{\"version\":\(version)}".utf8), isTruncated: false)
    }
}

@MainActor private final class DocumentReadGate {
    var continuation: CheckedContinuation<WorkspaceDocumentSnapshot, Never>?
    func read() async -> WorkspaceDocumentSnapshot {
        await withCheckedContinuation { continuation = $0 }
    }
}
