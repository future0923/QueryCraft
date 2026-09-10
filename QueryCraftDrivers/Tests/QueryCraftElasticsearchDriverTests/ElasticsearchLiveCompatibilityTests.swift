import Foundation
import QueryCraftFeature
import Synchronization
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch local live compatibility", .timeLimit(.minutes(5)))
struct ElasticsearchLiveCompatibilityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_ES_LIVE_TESTS"] == "1"),
          arguments: [19280, 19290])
    func localCluster(port: Int) async throws {
        // Deliberately restricted to the two disposable local containers.
        let configuration = try ElasticsearchConnectionConfiguration(DatabaseConnectionConfiguration(
            databaseType: .elasticsearch, databaseProduct: .elasticsearch,
            host: "127.0.0.1", port: port, authentication: .none,
            database: nil, tlsMode: .disabled))
        let fixture = Fixture(client: try ElasticsearchHTTPClient(configuration: configuration),
            session: try ElasticsearchWorkspaceSession(configuration: configuration))
        do {
            let root = try await fixture.send(.get, "/")
            let version = try #require((root["version"] as? [String: Any])?["number"] as? String)
            #expect(version.hasPrefix(port == 19280 ? "8." : "9."))
            try await fixture.prepare()
            try await fixture.session.connect()
            try await fixture.verifyPages()
            try await fixture.verifyWrites()
            try await fixture.verifyStream()
            await #expect(throws: (any Error).self) {
                _ = try await fixture.session.executeRequest(WorkspaceRequest(
                    method: .delete, path: "/\(fixture.index)/_doc/0"))
            }
            let response = try await fixture.client.perform(method: .post,
                path: "/\(fixture.index)/_search", body: Data(#"{"size":100}"#.utf8))
            #expect(response.body.count > 1024)
            await #expect(throws: ElasticsearchError.responseTooLarge(1024)) {
                _ = try await fixture.client.perform(method: .post,
                    path: "/\(fixture.index)/_search", body: Data(#"{"size":100}"#.utf8),
                    maximumResponseBytes: 1024)
            }
            #expect(try await fixture.session.fetchDataCount(
                for: fixture.object, in: "Elasticsearch") == 12_000)
            try await fixture.verifyLargeResponse()
            let keepFixtures = ProcessInfo.processInfo.environment["QUERYCRAFT_ES_KEEP_FIXTURES"] == "1"
            if keepFixtures {
                print("ES \(version) fixtures on 127.0.0.1:\(port): \(fixture.alias), \(fixture.largeIndex)")
            }
            await fixture.cleanup(removeFixtures: !keepFixtures)
        } catch {
            await fixture.cleanup()
            throw error
        }
    }

    private struct Fixture {
        let client: ElasticsearchHTTPClient
        let session: ElasticsearchWorkspaceSession
        let prefix = "qc_compat_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        var index: String { prefix + "_index" }
        var alias: String { prefix + "_alias" }
        var stream: String { prefix + "_stream" }
        var template: String { prefix + "_template" }
        var largeIndex: String { prefix + "_large" }
        var object: WorkspaceDatabaseObject { WorkspaceDatabaseObject(name: alias, kind: .elasticsearchAlias) }

        func send(_ method: WorkspaceRequestMethod, _ path: String,
                  body: [String: Any]? = nil) async throws -> [String: Any] {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let result = try await client.perform(method: method, path: path, body: data)
            return try #require(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        }

        func prepare() async throws {
            _ = try await send(.put, "/\(index)", body: [
                "settings": ["number_of_shards": 1, "number_of_replicas": 0],
                "aliases": [alias: ["is_write_index": true]],
                "mappings": ["properties": ["ordinal": ["type": "integer"],
                    "name": ["type": "text", "fields": ["keyword": ["type": "keyword"]]],
                    "enabled": ["type": "boolean"]]]])
            for start in stride(from: 0, to: 12_000, by: 500) {
                try Task.checkCancellation()
                var body = Data()
                for ordinal in start..<(start + 500) {
                    body.append(try JSONSerialization.data(withJSONObject: ["create": ["_id": String(ordinal)]]))
                    body.append(10)
                    body.append(try JSONSerialization.data(withJSONObject: [
                        "ordinal": ordinal, "name": "row \(ordinal)", "enabled": ordinal % 2 == 0]))
                    body.append(10)
                }
                let result = try await client.perform(method: .post, path: "/\(index)/_bulk", body: body)
                let root = try #require(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
                #expect(root["errors"] as? Bool == false)
            }
            _ = try await send(.post, "/\(index)/_refresh")
            _ = try await send(.put, "/_index_template/\(template)", body: [
                "index_patterns": [stream], "data_stream": [:], "priority": 500,
                "template": ["settings": ["number_of_shards": 1, "number_of_replicas": 0]]])
            _ = try await send(.put, "/_data_stream/\(stream)")
        }

        func page(_ offset: Int, limit: Int = 500,
                  sort: WorkspaceDatabaseDataSort = .ascending(columnName: "ordinal"),
                  filter: WorkspaceDatabaseDataFilter = .empty) async throws -> [String] {
            let ids = Mutex<[String]>([])
            _ = try await session.fetchDataPage(for: object, in: "Elasticsearch", offset: offset,
                limit: limit, sort: sort, filter: filter) { batch in
                guard let idColumn = batch.columns.first(where: { $0.name == "_id" }) else {
                    Issue.record("Missing document identity column")
                    return
                }
                ids.withLock { values in
                    values += batch.rows.compactMap {
                        if case .text(let id) = $0.value(at: idColumn.id) { return id }
                        return nil
                    }
                }
            }
            return ids.withLock { $0 }
        }

        func verifyPages() async throws {
            let objects = try await session.fetchObjects(in: "Elasticsearch")
            #expect(objects.contains { $0.name == alias && $0.kind == .elasticsearchAlias })
            #expect(objects.contains { $0.name == stream && $0.kind == .elasticsearchDataStream })
            let details = try await session.fetchDetails(for: object, in: "Elasticsearch")
            #expect(details.documentMappingFields?.contains { $0.path == "name.keyword" } == true)
            var all = try await page(0)
            await #expect(throws: ElasticsearchError.deepPageUnavailable) { _ = try await page(11_000) }
            for offset in stride(from: 500, to: 12_000, by: 500) {
                all += try await page(offset)
            }
            #expect(all == (0..<12_000).map(String.init))
            #expect(try await page(10_500) == (10_500..<11_000).map(String.init))
            let filter = WorkspaceDatabaseDataFilter(conditions: [WorkspaceDatabaseDataFilterCondition(
                columnName: "ordinal", columnKind: .elasticsearchNumber,
                operation: .rangeGreaterThanOrEqual, value: "11990")])
            #expect(try await page(0, filter: filter) == (11_990..<12_000).map(String.init))
            await #expect(throws: ElasticsearchError.deepPageUnavailable) {
                _ = try await page(11_000, filter: filter)
            }
            #expect(try await page(0, sort: .descending(columnName: "ordinal")).first == "11999")
            await #expect(throws: ElasticsearchError.deepPageUnavailable) { _ = try await page(11_000, limit: 100) }
        }

        func verifyWrites() async throws {
            let draft = WorkspaceDocumentCreationDraft(targetName: alias, targetKind: .alias,
                id: "routed /?#%+", routing: "tenant /+&=?#%",
                sourceJSON: Data(#"{"ordinal":12000,"name":"routed","enabled":true}"#.utf8))
            let prepared = try await session.prepareDocumentCreation(draft)
            let result = try await session.commitDocumentCreation(prepared)
            #expect(result.reference.index == index)
            #expect(result.reference.routing == draft.routing)
            let snapshot = try await session.fetchDocument(result.reference, maximumByteCount: 1_048_576)
            let update = try await session.prepareDocumentPartialUpdate(WorkspaceDocumentPartialUpdateDraft(
                reference: result.reference, sequenceNumber: try #require(snapshot.sequenceNumber),
                primaryTerm: try #require(snapshot.primaryTerm),
                sourceJSON: Data(#"{"ordinal":12000,"name":"changed","enabled":true}"#.utf8),
                changedFieldsJSON: Data(#"{"name":"changed"}"#.utf8)))
            let updated = try await session.commitDocumentPartialUpdate(update)
            await #expect(throws: WorkspaceDocumentEditingError.conflict) {
                _ = try await session.commitDocumentPartialUpdate(update)
            }
            let changed = try await session.fetchDocument(result.reference, maximumByteCount: 1_048_576)
            #expect(String(decoding: changed.sourceJSON, as: UTF8.self).contains("changed"))
            let replacement = try await session.prepareDocumentReplacement(WorkspaceDocumentReplacementDraft(
                reference: result.reference, sequenceNumber: updated.sequenceNumber,
                primaryTerm: updated.primaryTerm,
                sourceJSON: Data(#"{"ordinal":12000,"name":"replaced","enabled":false}"#.utf8)))
            let replaced = try await session.commitDocumentReplacement(replacement)
            let deletion = try await session.prepareDocumentDeletion(WorkspaceDocumentDeletionDraft(
                reference: result.reference, sequenceNumber: replaced.sequenceNumber, primaryTerm: replaced.primaryTerm))
            _ = try await session.commitDocumentDeletion(deletion)
            // The stale concurrency token also conflicts with the deletion tombstone.
            await #expect(throws: WorkspaceDocumentEditingError.conflict) {
                _ = try await session.commitDocumentDeletion(deletion)
            }
            do {
                _ = try await session.fetchDocument(result.reference, maximumByteCount: 1_048_576)
                Issue.record("Deleted document remained readable")
            } catch ElasticsearchError.server(let status, _) {
                #expect(status == 404)
            }
        }

        func verifyStream() async throws {
            let creation = try await session.prepareDocumentCreation(WorkspaceDocumentCreationDraft(
                targetName: stream, targetKind: .dataStream,
                sourceJSON: Data(#"{"@timestamp":"2026-09-08T00:00:00Z","name":"event"}"#.utf8)))
            let created = try await session.commitDocumentCreation(creation)
            #expect(created.reference.index.hasPrefix(".ds-" + stream))
            let snapshot = try await session.fetchDocument(created.reference, maximumByteCount: 1_048_576)
            let deletion = try await session.prepareDocumentDeletion(WorkspaceDocumentDeletionDraft(
                reference: created.reference, sequenceNumber: try #require(snapshot.sequenceNumber),
                primaryTerm: try #require(snapshot.primaryTerm)))
            _ = try await session.commitDocumentDeletion(deletion)
        }

        func verifyLargeResponse() async throws {
            _ = try await send(.put, "/\(largeIndex)", body: [
                "settings": ["number_of_shards": 1, "number_of_replicas": 0],
                "mappings": ["properties": ["payload": ["type": "keyword", "index": false, "doc_values": false]]]])
            let source = try JSONSerialization.data(withJSONObject: ["payload": String(repeating: "x", count: 400_000)])
            for start in stride(from: 0, to: 48, by: 2) {
                var body = Data()
                for id in start..<(start + 2) {
                    body.append(try JSONSerialization.data(withJSONObject: ["create": ["_id": String(id)]]))
                    body.append(10)
                    body.append(source)
                    body.append(10)
                }
                let response = try await client.perform(method: .post, path: "/\(largeIndex)/_bulk", body: body)
                let root = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
                #expect(root["errors"] as? Bool == false)
            }
            _ = try await send(.post, "/\(largeIndex)/_refresh")
            for method: WorkspaceRequestMethod in [.get, .post] {
                let response = try await session.executeRequest(WorkspaceRequest(method: method,
                    path: "/\(largeIndex)/_search", body: Data(#"{"size":48,"sort":["_doc"]}"#.utf8)))
                #expect(response.body.count > 16 * 1024 * 1024)
                let root = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
                let hits = try #require((root["hits"] as? [String: Any])?["hits"] as? [[String: Any]])
                #expect(hits.count == 48)
                #expect(Set(hits.compactMap { $0["_id"] as? String }) == Set((0..<48).map(String.init)))
                #expect(hits.allSatisfy { ($0["_source"] as? [String: Any])?["payload"] as? String == String(repeating: "x", count: 400_000) })
            }
            let normal = try await session.executeRequest(WorkspaceRequest(method: .post,
                path: "/\(largeIndex)/_search", body: Data(#"{"size":1}"#.utf8)))
            #expect(normal.body.count > 400_000)
            let page = try await session.fetchDataPage(
                for: WorkspaceDatabaseObject(name: largeIndex, kind: .elasticsearchIndex),
                in: "Elasticsearch", offset: 0, limit: 48, sort: .none,
                onBatch: { batch in #expect(batch.rows.count == 48) })
            #expect(!page.columns.isEmpty)
        }

        func cleanup(removeFixtures: Bool = true) async {
            await session.close()
            if removeFixtures {
                _ = try? await send(.delete, "/_data_stream/\(stream)")
                _ = try? await send(.delete, "/_index_template/\(template)")
                _ = try? await send(.delete, "/\(index)")
                _ = try? await send(.delete, "/\(largeIndex)")
            }
            await client.close()
        }
    }
}
