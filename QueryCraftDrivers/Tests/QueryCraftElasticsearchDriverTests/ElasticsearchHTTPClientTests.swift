import Foundation
import QueryCraftFeature
import Synchronization
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch HTTP client")
struct ElasticsearchHTTPClientTests {
    @Test("Completed write responses survive late cancellation; reads still cancel")
    func completedWriteCancellation() async throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "http://ack.local:9200/logs/_doc/1")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        ))
        let body = Data(#"{"result":"updated","_seq_no":11,"_primary_term":2}"#.utf8)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let result = try ElasticsearchHTTPClient.completedResponse(
                data: body, response: response, maximumResponseBytes: 1024,
                preserveCompletedResponse: true
            )
            #expect(result.body == body)
            #expect(throws: CancellationError.self) {
                try ElasticsearchHTTPClient.completedResponse(
                    data: body, response: response, maximumResponseBytes: 1024,
                    preserveCompletedResponse: false
                )
            }
            #expect(throws: ElasticsearchError.responseTooLarge(1)) {
                try ElasticsearchHTTPClient.completedResponse(
                    data: body, response: response, maximumResponseBytes: 1,
                    preserveCompletedResponse: true
                )
            }
        }
        try await task.value
    }

    @Test("Cancellation before a write sends no request")
    func cancelledWriteDoesNotStart() async throws {
        let host = "cancelled-write.local"
        let requests = Mutex(0)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            requests.withLock { $0 += 1 }
            return ElasticsearchURLProtocolStub.response(for: request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host: host, authentication: .none)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await client.perform(
                method: .put, path: "/logs/_doc/1", body: Data("{}".utf8),
                preserveCompletedResponse: true
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(requests.withLock { $0 } == 0)
        await client.close()
    }

    @Test("Builds Basic, API Key, and no-auth requests")
    func authenticationHeaders() async throws {
        let host = "auth.local"
        let observed = Mutex<[String?]>([])
        ElasticsearchURLProtocolStub.install(for: host) { request in
            observed.withLock {
                $0.append(request.value(forHTTPHeaderField: "Authorization"))
            }
            return ElasticsearchURLProtocolStub.response(for: request)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }

        for authentication in [
            DatabaseConnectionAuthentication.usernamePassword(
                username: "elastic",
                password: "secret"
            ),
            .apiKey("encoded-key"),
            .none,
        ] {
            let client = try makeClient(
                host: host,
                authentication: authentication
            )
            _ = try await client.perform(method: .get, path: "/")
            await client.close()
        }

        #expect(observed.withLock { $0 } == [
            "Basic ZWxhc3RpYzpzZWNyZXQ=",
            "ApiKey encoded-key",
            nil,
        ])
    }

    @Test("Rejects absolute URLs and enforces response limits")
    func pathAndResponseLimit() async throws {
        let host = "limits.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            ElasticsearchURLProtocolStub.response(
                for: request,
                json: #"{"value":"large"}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host: host, authentication: .none)

        await #expect(throws: ElasticsearchError.self) {
            _ = try await client.perform(
                method: .get,
                path: "https://example.com/_search"
            )
        }
        await #expect(throws: ElasticsearchError.responseTooLarge(4)) {
            _ = try await client.perform(
                method: .get,
                path: "/",
                maximumResponseBytes: 4
            )
        }
        await client.close()
    }

    @Test("Supports Elasticsearch 7.10 through future majors")
    func versions() {
        #expect(!ElasticsearchWorkspaceSession.isSupported(version: "7.9.3"))
        #expect(ElasticsearchWorkspaceSession.isSupported(version: "7.10.0"))
        #expect(ElasticsearchWorkspaceSession.isSupported(version: "8.18.1"))
        #expect(ElasticsearchWorkspaceSession.isSupported(version: "9.0.0"))
        #expect(!ElasticsearchWorkspaceSession.isSupported(version: "invalid"))
        #expect(!ElasticsearchWorkspaceSession.supportsShardDocSort(version: "7.10.2"))
        #expect(!ElasticsearchWorkspaceSession.supportsShardDocSort(version: "7.11.2"))
        #expect(ElasticsearchWorkspaceSession.supportsShardDocSort(version: "7.12.0"))
        #expect(ElasticsearchWorkspaceSession.supportsShardDocSort(version: "8.18.1"))
    }

    @Test("Surfaces the concrete Elasticsearch root cause")
    func rootCauseError() async throws {
        let host = "root-cause.local"
        ElasticsearchURLProtocolStub.install(for: host) { request in
            ElasticsearchURLProtocolStub.response(
                for: request,
                status: 400,
                json: #"{"error":{"root_cause":[{"type":"query_shard_exception","reason":"No mapping found for [_shard_doc] in order to sort on"}],"type":"search_phase_execution_exception","reason":"all shards failed"},"status":400}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let client = try makeClient(host: host, authentication: .none)

        await #expect(throws: ElasticsearchError.server(
            status: 400,
            message: "No mapping found for [_shard_doc] in order to sort on"
        )) {
            _ = try await client.perform(method: .post, path: "/logs/_search")
        }
        await client.close()
    }

    private func makeClient(
        host: String,
        authentication: DatabaseConnectionAuthentication
    ) throws -> ElasticsearchHTTPClient {
        let configuration = DatabaseConnectionConfiguration(
            databaseType: .elasticsearch,
            databaseProduct: .elasticsearch,
            host: host,
            port: 9_200,
            authentication: authentication,
            database: nil,
            tlsMode: .disabled
        )
        return try ElasticsearchHTTPClient(
            configuration: ElasticsearchConnectionConfiguration(configuration),
            protocolClasses: [ElasticsearchURLProtocolStub.self]
        )
    }
}
