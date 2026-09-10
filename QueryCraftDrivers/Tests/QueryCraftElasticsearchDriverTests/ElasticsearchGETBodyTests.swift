import Foundation
import Synchronization
import Testing
import QueryCraftFeature
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch GET body compatibility", .timeLimit(.minutes(1)))
struct ElasticsearchGETBodyTests {
    @Test(arguments: ["/_search", "/logs-*/_count?routing=tenant%2F1", "/logs/_msearch"])
    func preservesBodyAndRequestIdentity(path: String) async throws {
        let host = UUID().uuidString.lowercased() + ".local"
        let body = Data((path.contains("_msearch") ? "{}\n{\"query\":{\"match_all\":{}}}\n" : #"{ "number": 622887501937246211, "escaped": "\u4e2d" }"#).utf8)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "http://\(host):9200\(path)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "ApiKey test-key")
            #expect(Self.body(request) == body)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == (path.contains("_msearch") ? "application/x-ndjson" : "application/json"))
            return ElasticsearchURLProtocolStub.response(for: request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host)
        _ = try await client.perform(method: .get, path: path, body: body, enforceReadOnlyPolicy: true)
        await client.close()
    }

    @Test(arguments: ["/logs/_delete_by_query", "/_cluster/health", "/arbitrary/_nested/_search", "/logs/_search/", "//example.com/_search", "https://example.com/_search"])
    func unknownGETBodyNeverReachesNetwork(path: String) async throws {
        let host = UUID().uuidString.lowercased() + ".local"
        let requests = Mutex(0)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            requests.withLock { $0 += 1 }
            return ElasticsearchURLProtocolStub.response(for: request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host)
        await #expect(throws: (any Error).self) {
            _ = try await client.perform(method: .get, path: path, body: Data("{}".utf8))
        }
        #expect(requests.withLock { $0 } == 0)
        await client.close()
    }

    @Test
    func emptyGETRemainsGET() async throws {
        let host = "empty-get.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            #expect(request.httpMethod == "GET")
            #expect(Self.body(request).isEmpty)
            return ElasticsearchURLProtocolStub.response(for: request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host)
        _ = try await client.perform(method: .get, path: "/_cluster/health")
        _ = try await client.perform(method: .get, path: "/_cluster/health", body: Data())
        await client.close()
    }

    @Test
    func cancellationStopsAdaptedGETAndConnectionRecovers() async throws {
        let host = "cancel-get-body.local"
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        ElasticsearchURLProtocolStub.install(for: host, finishesLoading: false, onStop: {
            stopped.continuation.yield(())
            stopped.continuation.finish()
        }) { request in
            #expect(request.httpMethod == "POST")
            started.continuation.yield(())
            started.continuation.finish()
            return ElasticsearchURLProtocolStub.response(for: request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host)
        let task = Task { try await client.perform(method: .get, path: "/_search", body: Data("{}".utf8)) }
        var starts = started.stream.makeAsyncIterator()
        #expect(await starts.next() != nil)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        var stops = stopped.stream.makeAsyncIterator()
        #expect(await stops.next() != nil)
        ElasticsearchURLProtocolStub.install(for: host) { ElasticsearchURLProtocolStub.response(for: $0) }
        #expect(try await client.perform(method: .get, path: "/").body == Data("{}".utf8))
        await client.close()
    }

    private func makeClient(_ host: String) throws -> ElasticsearchHTTPClient {
        try ElasticsearchHTTPClient(configuration: ElasticsearchConnectionConfiguration(
            DatabaseConnectionConfiguration(databaseType: .elasticsearch, databaseProduct: .elasticsearch,
                host: host, port: 9200, authentication: .apiKey("test-key"), database: nil, tlsMode: .disabled)),
            protocolClasses: [ElasticsearchURLProtocolStub.self])
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
