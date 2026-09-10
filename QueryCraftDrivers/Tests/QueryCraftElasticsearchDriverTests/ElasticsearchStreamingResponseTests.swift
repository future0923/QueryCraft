import Foundation
import QueryCraftFeature
import Synchronization
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch bounded streaming", .timeLimit(.minutes(1)))
struct ElasticsearchStreamingResponseTests {
    @Test("Rejects an unfinished oversized response and cancels its download", arguments: [false, true])
    func unfinishedResponse(advertisesLength: Bool) async throws {
        let host = advertisesLength ? "large-header.local" : "large-stream.local"
        let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        ElasticsearchURLProtocolStub.install(for: host, finishesLoading: false, onStop: {
            stopped.continuation.yield(())
            stopped.continuation.finish()
        }) { request in
            var headers = ["Content-Type": "application/json"]
            if advertisesLength { headers["Content-Length"] = "1000000000" }
            return ElasticsearchURLProtocolStub.response(for: request, headers: headers,
                json: String(repeating: "x", count: 4096))
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host: host)
        await #expect(throws: ElasticsearchError.responseTooLarge(1024)) {
            _ = try await client.perform(method: .get, path: "/_search", maximumResponseBytes: 1024)
        }
        var stops = stopped.stream.makeAsyncIterator()
        #expect(await stops.next() != nil)

        ElasticsearchURLProtocolStub.install(for: host) { request in
            ElasticsearchURLProtocolStub.response(for: request)
        }
        let recovered = try await client.perform(method: .get, path: "/")
        #expect(recovered.body == Data("{}".utf8))
        await client.close()
    }

    @Test("HEAD ignores representation length and accepts an empty response")
    func headResponse() async throws {
        let host = "head-length.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            ElasticsearchURLProtocolStub.response(for: request,
                headers: ["Content-Length": "1000000000"], json: "")
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host: host)
        let result = try await client.perform(method: .head, path: "/logs", maximumResponseBytes: 0)
        #expect(result.body.isEmpty)
        await client.close()
    }

    @Test("Retains exact bytes at the limit and stops an unbounded source at limit plus one")
    func exactBoundary() async throws {
        let limit = 131_072
        let body = try await ElasticsearchHTTPClient.readBody(
            from: LazyBytes(count: limit), maximumByteCount: limit)
        #expect(body.count == limit)
        #expect(body.enumerated().allSatisfy { $0.element == UInt8(truncatingIfNeeded: $0.offset) })
        let consumed = Mutex(0)
        await #expect(throws: ElasticsearchError.responseTooLarge(7)) {
            _ = try await ElasticsearchHTTPClient.readBody(
                from: LazyBytes(count: Int.max, observe: { count in consumed.withLock { $0 = count } }),
                maximumByteCount: 7)
        }
        #expect(consumed.withLock { $0 } == 8)
        let empty = try await ElasticsearchHTTPClient.readBody(
            from: LazyBytes(count: 0), maximumByteCount: 0)
        #expect(empty.isEmpty)
    }

    @Test("Checks cancellation while consuming a synchronous byte producer")
    func cancellationDuringBody() async throws {
        let consumed = Mutex(0)
        let task = Task {
            try await ElasticsearchHTTPClient.readBody(
                from: LazyBytes(count: Int.max, observe: { count in
                    consumed.withLock { $0 = count }
                    if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }), maximumByteCount: 1_048_576)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(consumed.withLock { $0 } <= 65_536)
    }

    @Test("Transport timeout is preserved rather than returning a partial body")
    func timeout() async throws {
        let host = "stream-timeout.local"
        ElasticsearchURLProtocolStub.install(for: host) { _ in throw URLError(.timedOut) }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host: host)
        await #expect(throws: ElasticsearchError.self) {
            _ = try await client.perform(method: .get, path: "/")
        }
        await client.close()
    }

    @Test("Consumes a representative 16 MiB body without a materialized producer")
    func largeBody() async throws {
        let limit = 16 * 1024 * 1024
        let result = try await ElasticsearchHTTPClient.readBody(
            from: LazyBytes(count: limit), maximumByteCount: limit)
        #expect(result.count == limit)
        #expect(result.first == 0)
        #expect(result.last == 255)
    }

    private func makeClient(host: String) throws -> ElasticsearchHTTPClient {
        try ElasticsearchHTTPClient(configuration: ElasticsearchConnectionConfiguration(
            DatabaseConnectionConfiguration(databaseType: .elasticsearch, databaseProduct: .elasticsearch,
                host: host, port: 9200, authentication: .none, database: nil, tlsMode: .disabled)),
            protocolClasses: [ElasticsearchURLProtocolStub.self])
    }

    private struct LazyBytes: AsyncSequence, Sendable {
        typealias Element = UInt8
        let count: Int
        var observe: (@Sendable (Int) -> Void)?
        func makeAsyncIterator() -> Iterator { Iterator(source: self) }
        struct Iterator: AsyncIteratorProtocol {
            let source: LazyBytes
            var index = 0
            mutating func next() async throws -> UInt8? {
                guard index < source.count else { return nil }
                let byte = UInt8(truncatingIfNeeded: index)
                index += 1
                source.observe?(index)
                return byte
            }
        }
    }
}
