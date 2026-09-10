import Foundation
import Testing
@testable import QueryCraftFeature

@Suite(.timeLimit(.minutes(3)))
struct WorkspaceElasticsearchIndexSettingsLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_ES_LIVE_TESTS"] == "1"), arguments: [19280, 19290])
    @MainActor func realIndexSettingsCountDefaultsAliasAndExternalConflict(port: Int) async throws {
        let (workspace, _) = await indexDeletionFixture(port: port)
        workspace.safetyLock.disable()
        let name = "qc_index_settings_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let alias = name + "_alias"
        let worker = WorkspaceIndexSettingsWorker()
        do {
            let created = try await workspace.executeElasticsearchRequest(.init(method: .put, path: "/" + name,
                body: Data(#"{"settings":{"number_of_shards":1,"number_of_replicas":0},"mappings":{"properties":{"name":{"type":"keyword"},"children":{"type":"nested"}}}}"#.utf8)))
            #expect(created.statusCode == 200)
            let document = try await workspace.executeElasticsearchRequest(.init(method: .put, path: "/" + name + "/_doc/one?refresh=true",
                body: Data(#"{"name":"one","children":[{"name":"a"},{"name":"b"}]}"#.utf8)))
            #expect(document.statusCode == 201)
            let snapshot = try await worker.load(indexSelection(name)) { request in try await workspace.executeElasticsearchRequest(request) }
            #expect(snapshot.documentCount == 1) // Two nested Lucene docs must not inflate the document count.
            #expect(snapshot.storeBytes != nil && snapshot.health != nil && snapshot.warnings.isEmpty)
            #expect(snapshot.editableIndex?.settings["index.refresh_interval"] == nil)
            #expect(snapshot.editableIndex?.effective("index.refresh_interval") == "1s")
            let prepared = try await worker.prepare(snapshot, replicas: "0", interval: "5s")
            let committed = try await workspace.commitElasticsearchIndexSettings(prepared)
            #expect(await worker.acknowledged(committed))
            let read = try await workspace.executeElasticsearchRequest(worker.settingsRequest(indexSelection(name)))
            #expect(try await worker.matches(prepared, response: read))
            // Reusing an old baseline must fail before any second PUT.
            await #expect(throws: WorkspaceIndexSettingsNotSentError.self) { try await workspace.commitElasticsearchIndexSettings(prepared) }
            let aliased = try await workspace.executeElasticsearchRequest(.init(method: .put, path: "/" + name + "/_alias/" + alias))
            #expect(aliased.statusCode == 200)
            let aliasSnapshot = try await worker.load(.init(databaseName: "Elasticsearch", objectName: alias, kind: .elasticsearchAlias)) {
                try await workspace.executeElasticsearchRequest($0)
            }
            #expect(aliasSnapshot.editableIndex == nil && aliasSnapshot.indices.map(\.name) == [name] && aliasSnapshot.documentCount == 1)
            let deleted = try await workspace.executeElasticsearchRequest(.init(method: .delete, path: "/" + name))
            #expect(deleted.statusCode == 200)
        } catch {
            _ = try? await workspace.executeElasticsearchRequest(.init(method: .delete, path: "/" + name))
            await workspace.disconnect()
            throw error
        }
        await workspace.disconnect()
    }
}
