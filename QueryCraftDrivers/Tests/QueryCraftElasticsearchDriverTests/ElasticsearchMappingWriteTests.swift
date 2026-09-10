import Foundation
import QueryCraftFeature
import Synchronization
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite(.timeLimit(.minutes(2)))
struct ElasticsearchMappingWriteTests {
    @Test(arguments: [401, 403, 404, 409, 429, 500])
    func consolePreservesHTTPErrorAndRequiresPolicy(status: Int) async throws {
        let host = "write-policy-\(status).local"
        let sends = Mutex(0)
        let body = #"{"error":{"reason":"full error","metadata":18446744073709551615}}"#
        ElasticsearchURLProtocolStub.install(for: host) { request in
            if request.url?.path == "/" { return Self.root(request) }
            sends.withLock { $0 += 1 }
            return ElasticsearchURLProtocolStub.response(for: request, status: status, json: body)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let request = WorkspaceRequest(method: .post, path: "/_unknown", body: Data("{}".utf8))
        await #expect(throws: (any Error).self) { _ = try await session.executeRequest(request) }
        #expect(sends.withLock { $0 } == 0)
        let response = try await session.executeRequest(request, policy: .writesAllowed)
        #expect(response.statusCode == status)
        #expect(response.body == Data(body.utf8))
        #expect(sends.withLock { $0 } == 1)
        await session.close()
    }

    @Test func preparesConcreteMinimalMappingAndRejectsTampering() async throws {
        let host = "mapping-integrity.local"
        let writes = Mutex<[String]>([])
        let mapping = #"{"logs":{"mappings":{"properties":{"name":{"type":"text"}}}}}"#
        ElasticsearchURLProtocolStub.install(for: host) { request in
            let path = request.url?.path ?? ""
            if path == "/" { return Self.root(request) }
            if request.httpMethod == "PUT" {
                writes.withLock { $0.append(path) }
                return ElasticsearchURLProtocolStub.response(for: request, json: #"{"acknowledged":true}"#)
            }
            if path.hasPrefix("/_resolve") { return ElasticsearchURLProtocolStub.response(for: request, json: #"{"indices":[{"name":"logs"}]}"#) }
            if path.hasSuffix("_field_caps") { return ElasticsearchURLProtocolStub.response(for: request, json: #"{"fields":{}}"#) }
            return ElasticsearchURLProtocolStub.response(for: request, json: mapping)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let snapshot = try await session.fetchMappingSnapshot(.init(resource: "logs", kind: .elasticsearchIndex))
        let draft = WorkspaceMappingDraft(baseline: snapshot, changes: [.init(path: ["properties", "name", "fields", "keyword"], definitionJSON: Data(#"{"type":"keyword"}"#.utf8), isNew: true)])
        let prepared = try await session.prepareMappingUpdate(draft)
        #expect(prepared.request.path == "/logs/_mapping")
        let altered = WorkspacePreparedMappingUpdate(draft: draft, request: .init(method: .delete, path: "/logs"))
        await #expect(throws: (any Error).self) { _ = try await session.commitMappingUpdate(altered) }
        #expect(writes.withLock { $0.isEmpty })
        #expect(try await session.commitMappingUpdate(prepared).statusCode == 200)
        #expect(writes.withLock { $0 } == ["/logs/_mapping"])
        await session.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUERYCRAFT_ES_LIVE_TESTS"] == "1"), arguments: [19280, 19290])
    func liveMappingAndREST(port: Int) async throws {
        let session = try makeSession(host: "127.0.0.1", port: port, stub: false)
        try await session.connect()
        let prefix = "qc_mapping_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let index = prefix + "_index", secondIndex = prefix + "_other", alias = prefix + "_alias", stream = prefix + "_stream", template = prefix + "_template"
        func send(_ method: WorkspaceRequestMethod, _ path: String, _ body: String? = nil) async throws -> WorkspaceRequestExecutionResult {
            let response = try await session.executeRequest(.init(method: method, path: path, body: body.map { Data($0.utf8) }), policy: .writesAllowed)
            #expect((200..<300).contains(response.statusCode), "\(path): \(String(decoding: response.body, as: UTF8.self))")
            return response
        }
        do {
            _ = try await send(.put, "/\(index)", "{\"settings\":{\"number_of_replicas\":0},\"aliases\":{\"\(alias)\":{}},\"mappings\":{\"properties\":{\"name\":{\"type\":\"text\"}}}}")
            let aliasSnapshot = try await session.fetchMappingSnapshot(.init(resource: alias, kind: .elasticsearchAlias))
            #expect(Set(aliasSnapshot.indexMappings.keys) == [index])
            _ = try await send(.put, "/\(secondIndex)", "{\"settings\":{\"number_of_replicas\":0},\"aliases\":{\"\(alias)\":{}},\"mappings\":{\"properties\":{\"name\":{\"type\":\"keyword\"}}}}")
            let merged = try await session.fetchMappingSnapshot(aliasSnapshot.target)
            #expect(Set(merged.indexMappings.keys) == [index, secondIndex])
            #expect(merged.fields.first(where: { $0.name == "name" })?.hasConflict == true)
            let snapshot = try await session.fetchMappingSnapshot(.init(resource: index, kind: .elasticsearchIndex))
            let changes: [WorkspaceMappingFieldChange] = [
                .init(path: ["properties", "name", "fields", "keyword"], definitionJSON: Data(#"{"type":"keyword","ignore_above":256}"#.utf8), isNew: true),
                .init(path: ["properties", "profile"], definitionJSON: Data(#"{"type":"object"}"#.utf8), isNew: true),
                .init(path: ["properties", "profile", "properties", "city"], definitionJSON: Data(#"{"type":"keyword"}"#.utf8), isNew: true)]
            let draft = WorkspaceMappingDraft(baseline: snapshot, changes: changes)
            let prepared = try await session.prepareMappingUpdate(draft)
            #expect(try await session.commitMappingUpdate(prepared).statusCode == 200)
            let updated = try await session.fetchMappingSnapshot(snapshot.target)
            #expect(try WorkspaceMappingCodec.containsChanges(draft, current: updated))
            let untouched = try await session.fetchMappingSnapshot(.init(resource: secondIndex, kind: .elasticsearchIndex))
            #expect(!untouched.fields.contains { $0.name == "profile" || $0.name == "city" })
            await #expect(throws: (any Error).self) { _ = try await session.commitMappingUpdate(prepared) }
            let value = #"{"name":"中文","large":622887501937246211,"profile":{"city":"沈阳"}}"#
            _ = try await send(.put, "/\(index)/_doc/one?refresh=wait_for", value)
            let read = try await send(.get, "/\(index)/_doc/one")
            #expect(String(decoding: read.body, as: UTF8.self).contains("622887501937246211"))
            _ = try await send(.post, "/\(index)/_update/one?refresh=wait_for", #"{"doc":{"name":"changed"}}"#)
            _ = try await send(.delete, "/\(index)/_doc/one")
            _ = try await send(.put, "/_index_template/\(template)", "{\"index_patterns\":[\"\(stream)\"],\"data_stream\":{},\"priority\":500,\"template\":{\"settings\":{\"number_of_replicas\":0}}}")
            _ = try await send(.put, "/_data_stream/\(stream)")
            let streamSnapshot = try await session.fetchMappingSnapshot(.init(resource: stream, kind: .elasticsearchDataStream))
            let streamDraft = WorkspaceMappingDraft(baseline: streamSnapshot, changes: [.init(path: ["properties", "message"], definitionJSON: Data(#"{"type":"keyword"}"#.utf8), isNew: true)])
            let streamPrepared = try await session.prepareMappingUpdate(streamDraft)
            #expect(streamPrepared.request.path == "/\(stream)/_mapping")
            _ = try await session.commitMappingUpdate(streamPrepared)
            #expect(try WorkspaceMappingCodec.containsChanges(streamDraft, current: await session.fetchMappingSnapshot(streamSnapshot.target)))
            let templateResponse = try await send(.get, "/_index_template/\(template)")
            #expect(!String(decoding: templateResponse.body, as: UTF8.self).contains("message"))
        } catch {
            for path in ["/_data_stream/\(stream)", "/_index_template/\(template)", "/\(index)", "/\(secondIndex)"] { _ = try? await session.executeRequest(.init(method: .delete, path: path), policy: .writesAllowed) }
            await session.close(); throw error
        }
        for path in ["/_data_stream/\(stream)", "/_index_template/\(template)", "/\(index)", "/\(secondIndex)"] { _ = try? await session.executeRequest(.init(method: .delete, path: path), policy: .writesAllowed) }
        await session.close()
    }

    private func makeSession(host: String, port: Int = 9200, stub: Bool = true) throws -> ElasticsearchWorkspaceSession {
        let configuration = try ElasticsearchConnectionConfiguration(DatabaseConnectionConfiguration(databaseType: .elasticsearch, databaseProduct: .elasticsearch, host: host, port: port, authentication: .none, database: nil, tlsMode: .disabled))
        return try ElasticsearchWorkspaceSession(configuration: configuration, protocolClasses: stub ? [ElasticsearchURLProtocolStub.self] : [])
    }
    private static func root(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        ElasticsearchURLProtocolStub.response(for: request, headers: ["Content-Type":"application/json", "X-Elastic-Product":"Elasticsearch"], json: #"{"version":{"number":"8.18.0"},"tagline":"You Know, for Search"}"#)
    }
}
