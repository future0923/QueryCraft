import Foundation
import QueryCraftFeature
import Synchronization
import Testing
@testable import QueryCraftElasticsearchDriver

@Suite("Elasticsearch pagination")
struct ElasticsearchPaginationTests {
    @Test("Non-PIT pagination never reads past the 10,000 document window")
    func fallbackWindowBoundary() async throws {
        let host = "fallback-window.local"
        installBaseHandler(host: host, version: "7.10.2") { request in
            let body = try JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any]
            let offset = body?["from"] as? Int ?? 0
            let size = body?["size"] as? Int ?? 0
            guard offset + size <= 10_000 else {
                return ElasticsearchURLProtocolStub.response(for: request, status: 400,
                    json: #"{"error":"Result window is too large"}"#)
            }
            return Self.searchResponse(request, ids: (offset..<(offset + size)).map(String.init))
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let object = WorkspaceDatabaseObject(name: "logs", kind: .elasticsearchIndex)
        _ = try await session.fetchDataPage(for: object, in: "Elasticsearch", offset: 9000,
            limit: 500, sort: .none, onBatch: { _ in })
        let last = try await session.fetchDataPage(for: object, in: "Elasticsearch", offset: 9500,
            limit: 500, sort: .none, onBatch: { batch in #expect(batch.rows.count == 500) })
        #expect(!last.hasNextPage)
        await #expect(throws: ElasticsearchError.deepPageUnavailable) {
            _ = try await session.fetchDataPage(for: object, in: "Elasticsearch", offset: 10_000,
                limit: 500, sort: .none, onBatch: { _ in })
        }
        await session.close()
    }

    private final class CompatibilityObservation: Sendable {
        let openedPIT = Mutex(false)
        let searchBody = Mutex<Data?>(nil)
    }

    @Test("Uses PIT search_after for sequential next and cached previous pages")
    func searchAfter() async throws {
        let host = "paging.local"
        let searchBodies = Mutex<[Data]>([])
        let searchCount = Mutex(0)
        installBaseHandler(host: host) { request in
            let body = Self.requestBody(request)
            searchBodies.withLock { $0.append(body) }
            let count = searchCount.withLock { value in
                value += 1
                return value
            }
            return count == 1
                ? Self.searchResponse(request, ids: ["1", "2"])
                : Self.searchResponse(request, ids: ["3"])
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let object = WorkspaceDatabaseObject(
            name: "logs",
            kind: .elasticsearchIndex
        )

        let batchRowCounts = Mutex<[Int]>([])
        _ = try await session.fetchDataPage(
            for: object,
            in: "Elasticsearch",
            offset: 0,
            limit: 2,
            sort: .none,
            onBatch: { batch in
                batchRowCounts.withLock { $0.append(batch.rows.count) }
            }
        )
        let result = try await session.fetchDataPage(
            for: object,
            in: "Elasticsearch",
            offset: 2,
            limit: 2,
            sort: .none,
            onBatch: { batch in
                batchRowCounts.withLock { $0.append(batch.rows.count) }
            }
        )

        #expect(batchRowCounts.withLock { $0 } == [2, 1])
        #expect(!result.hasNextPage)
        let bodies = searchBodies.withLock { $0 }
        let second = try #require(
            JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any]
        )
        #expect((second["search_after"] as? [Int]) == [2])
        await session.close()
    }

    @Test("Displays only top-level source fields and preserves JSON cells")
    func sourceDocumentValues() async throws {
        let host = "source-values.local"
        let searchBody = Mutex<Data?>(nil)
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    headers: [
                        "Content-Type": "application/json",
                        "X-Elastic-Product": "Elasticsearch",
                    ],
                    json: #"{"version":{"number":"8.18.0"},"tagline":"You Know, for Search"}"#
                )
            case ("GET", "/broker/_mapping"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"broker":{"mappings":{"properties":{"areaBoCodeList":{"type":"keyword"},"areaBOList":{"type":"nested","properties":{"areaCode":{"type":"text","fields":{"keyword":{"type":"keyword"}}},"areaName":{"type":"text","fields":{"keyword":{"type":"keyword"}}}}},"brokerId":{"type":"long"},"name":{"type":"keyword"},"unused":{"type":"keyword"}}}}}"#
                )
            case ("POST", "/broker/_field_caps"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"fields":{"_seq_no":{"long":{"searchable":false,"aggregatable":false}},"_source":{"_source":{"searchable":false,"aggregatable":false}},"_type":{"_type":{"searchable":false,"aggregatable":false}},"_version":{"long":{"searchable":false,"aggregatable":false}},"areaBoCodeList":{"keyword":{"searchable":true,"aggregatable":true}},"areaBOList":{"nested":{"searchable":false,"aggregatable":false}},"areaBOList.areaCode":{"text":{"searchable":true,"aggregatable":false}},"areaBOList.areaCode.keyword":{"keyword":{"searchable":true,"aggregatable":true}},"areaBOList.areaName":{"text":{"searchable":true,"aggregatable":false}},"areaBOList.areaName.keyword":{"keyword":{"searchable":true,"aggregatable":true}},"brokerId":{"long":{"searchable":true,"aggregatable":true}},"name":{"keyword":{"searchable":true,"aggregatable":true}},"unused":{"keyword":{"searchable":true,"aggregatable":true}}}}"#
                )
            case ("POST", "/broker/_pit"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"id":"pit-id"}"#
                )
            case ("POST", "/_search"):
                searchBody.withLock { $0 = Self.requestBody(request) }
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"pit_id":"pit-id","hits":{"hits":[{"_id":"1","_index":"broker","_score":null,"_source":{"areaBoCodeList":["2201040010","2201040012"],"areaBOList":[{"areaCode":"2201040010","areaName":"文化广场"},{"areaCode":"2201040012","areaName":"欧亚卖场"}],"brokerId":622887501937246211,"name":"袁立伟zq"},"sort":[1]}]}}"#
                )
            case ("DELETE", "/_pit"):
                return ElasticsearchURLProtocolStub.response(for: request)
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let receivedBatch = Mutex<WorkspaceDatabaseDataBatch?>(nil)

        _ = try await session.fetchDataPage(
            for: WorkspaceDatabaseObject(
                name: "broker",
                kind: .elasticsearchIndex
            ),
            in: "Elasticsearch",
            offset: 0,
            limit: 100,
            sort: .none,
            onBatch: { batch in receivedBatch.withLock { $0 = batch } }
        )

        let requestData = try #require(searchBody.withLock { $0 })
        let request = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        #expect(request["_source"] as? Bool == true)

        let batch = try #require(receivedBatch.withLock { $0 })
        #expect(!batch.columns.contains { $0.name == "_seq_no" })
        #expect(!batch.columns.contains { $0.name == "_source" })
        #expect(!batch.columns.contains { $0.name == "_type" })
        #expect(!batch.columns.contains { $0.name == "_version" })
        #expect(!batch.columns.contains { $0.name == "areaBOList.areaCode" })
        #expect(
            !batch.columns.contains {
                $0.name == "areaBOList.areaCode.keyword"
            }
        )
        #expect(batch.columns.contains { $0.name == "unused" })
        let row = try #require(batch.rows.first)
        let values = Dictionary(uniqueKeysWithValues: zip(
            batch.columns.map(\.name),
            row.values
        ))
        #expect(values["brokerId"] == .text("622887501937246211"))
        #expect(values["name"] == .text("袁立伟zq"))
        #expect(values["unused"] == .null)
        #expect(
            values["areaBoCodeList"]
                == .text(#"["2201040010","2201040012"]"#)
        )
        #expect(
            values["areaBOList"]
                == .text(
                    #"[{"areaCode":"2201040010","areaName":"文化广场"},{"areaCode":"2201040012","areaName":"欧亚卖场"}]"#
                )
        )
        await session.close()
    }

    @Test("Preserves numeric zero and one without converting them to booleans")
    func numericAndBooleanDocumentValues() async throws {
        let host = "numeric-boolean-values.local"
        installBaseHandler(host: host) { request in
            ElasticsearchURLProtocolStub.response(for: request,
                json: #"{"pit_id":"pit-id","hits":{"hits":[{"_id":"1","_index":"logs","_score":1,"_source":{"name":1,"count":0,"enabled":true,"disabled":false,"numericText":"1","zeroText":"0","booleanText":"false","negative":-1,"decimal":0.5,"large":622887501937246211,"missing":null,"array":[0,1,true,false],"nested":{"count":1}},"sort":[1]}]}}"#)
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let receivedBatch = Mutex<WorkspaceDatabaseDataBatch?>(nil)
        _ = try await session.fetchDataPage(
            for: WorkspaceDatabaseObject(name: "logs", kind: .elasticsearchIndex),
            in: "Elasticsearch", offset: 0, limit: 100, sort: .none,
            onBatch: { batch in receivedBatch.withLock { $0 = batch } })
        let batch = try #require(receivedBatch.withLock { $0 })
        let row = try #require(batch.rows.first)
        let cells = Dictionary(uniqueKeysWithValues: zip(batch.columns.map(\.name), row.values))
        #expect(cells["name"] == .text("1"))
        #expect(cells["count"] == .text("0"))
        #expect(cells["_score"] == .text("1"))
        #expect(cells["enabled"] == .text("true"))
        #expect(cells["disabled"] == .text("false"))
        #expect(cells["numericText"] == .text("1"))
        #expect(cells["zeroText"] == .text("0"))
        #expect(cells["booleanText"] == .text("false"))
        #expect(cells["negative"] == .text("-1"))
        #expect(cells["decimal"] == .text("0.5"))
        #expect(cells["large"] == .text("622887501937246211"))
        #expect(cells["missing"] == .null)
        #expect(cells["array"] == .text("[0,1,true,false]"))
        #expect(cells["nested"] == .text(#"{"count":1}"#))
        await session.close()
    }

    @Test("Preserves routing from Elasticsearch hit metadata shapes")
    func routingMetadataShapes() async throws {
        let host = "routing-metadata.local"
        installBaseHandler(host: host) { request in
            ElasticsearchURLProtocolStub.response(
                for: request,
                json: #"{"pit_id":"pit-id","hits":{"hits":[{"_id":"top","_index":"logs","_routing":"tenant-top","_source":{"message":"a"},"sort":[1]},{"_id":"array","_index":"logs","fields":{"_routing":["tenant-array"]},"_source":{"message":"b"},"sort":[2]},{"_id":"string","_index":"logs","fields":{"_routing":"tenant-string"},"_source":{"message":"c"},"sort":[3]}]}}"#
            )
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()
        let receivedBatch = Mutex<WorkspaceDatabaseDataBatch?>(nil)

        _ = try await session.fetchDataPage(
            for: WorkspaceDatabaseObject(
                name: "logs",
                kind: .elasticsearchIndex
            ),
            in: "Elasticsearch",
            offset: 0,
            limit: 100,
            sort: .none,
            onBatch: { batch in receivedBatch.withLock { $0 = batch } }
        )

        let batch = try #require(receivedBatch.withLock { $0 })
        let routingColumn = try #require(
            batch.columns.first(where: { $0.name == "_routing" })
        )
        #expect(batch.rows.map { $0.value(at: routingColumn.id) } == [
            .text("tenant-top"),
            .text("tenant-array"),
            .text("tenant-string"),
        ])
        await session.close()
    }

    @Test("Reopens an expired PIT once")
    func expiredPITRecovery() async throws {
        let host = "pit-expiry.local"
        let searches = Mutex(0)
        installBaseHandler(host: host) { request in
            let attempt = searches.withLock { value in
                value += 1
                return value
            }
            if attempt == 1 {
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":{"type":"resource_not_found_exception","reason":"point in time missing"},"status":404}"#
                )
            }
            return Self.searchResponse(request, ids: ["1"])
        }
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()

        let rowCount = Mutex(0)
        _ = try await session.fetchDataPage(
            for: WorkspaceDatabaseObject(
                name: "logs",
                kind: .elasticsearchIndex
            ),
            in: "Elasticsearch",
            offset: 0,
            limit: 100,
            sort: .none,
            onBatch: { batch in
                rowCount.withLock { $0 = batch.rows.count }
            }
        )

        #expect(searches.withLock { $0 } == 2)
        #expect(rowCount.withLock { $0 } == 1)
        await session.close()
    }

    @Test("Elasticsearch 7.10 falls back to the 10,000 row window")
    func elasticsearch710Fallback() async throws {
        let host = "seven-ten.local"
        let observation = CompatibilityObservation()
        installCompatibilityHandler(
            host: host,
            version: "7.10.2",
            pitStatus: 200,
            observation: observation
        )
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()

        _ = try await session.fetchDataPage(
            for: WorkspaceDatabaseObject(
                name: "logs",
                kind: .elasticsearchIndex
            ),
            in: "Elasticsearch",
            offset: 0,
            limit: 100,
            sort: .none,
            onBatch: { _ in }
        )

        #expect(!observation.openedPIT.withLock { $0 })
        let body = try #require(observation.searchBody.withLock { $0 })
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let sort = try #require(object["sort"] as? [[String: String]])
        #expect(sort == [["_doc": "asc"]])
        #expect(object["pit"] == nil)
        await session.close()
    }

    @Test("PIT permission fallback uses a non-PIT sort")
    func forbiddenPITFallback() async throws {
        let host = "pit-forbidden.local"
        let observation = CompatibilityObservation()
        installCompatibilityHandler(
            host: host,
            version: "8.18.0",
            pitStatus: 403,
            observation: observation
        )
        defer { ElasticsearchURLProtocolStub.reset(host: host) }
        let session = try makeSession(host: host)
        try await session.connect()

        _ = try await session.fetchDataPage(
            for: WorkspaceDatabaseObject(
                name: "logs",
                kind: .elasticsearchIndex
            ),
            in: "Elasticsearch",
            offset: 0,
            limit: 100,
            sort: .none,
            onBatch: { _ in }
        )

        #expect(observation.openedPIT.withLock { $0 })
        let body = try #require(observation.searchBody.withLock { $0 })
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let sort = try #require(object["sort"] as? [[String: String]])
        #expect(sort == [["_doc": "asc"]])
        #expect(object["pit"] == nil)
        await session.close()
    }

    private func makeSession(
        host: String
    ) throws -> ElasticsearchWorkspaceSession {
        let configuration = DatabaseConnectionConfiguration(
            databaseType: .elasticsearch,
            databaseProduct: .elasticsearch,
            host: host,
            port: 9_200,
            authentication: .none,
            database: nil,
            tlsMode: .disabled
        )
        return try ElasticsearchWorkspaceSession(
            configuration: ElasticsearchConnectionConfiguration(configuration),
            protocolClasses: [ElasticsearchURLProtocolStub.self]
        )
    }

    private func installBaseHandler(
        host: String,
        version: String = "8.18.0",
        search: @escaping ElasticsearchURLProtocolStub.Handler
    ) {
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    headers: [
                        "Content-Type": "application/json",
                        "X-Elastic-Product": "Elasticsearch",
                    ],
                    json: #"{"version":{"number":"\#(version)"},"tagline":"You Know, for Search"}"#
                )
            case ("GET", "/logs/_mapping"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"logs":{"mappings":{"properties":{"message":{"type":"keyword"}}}}}"#
                )
            case ("POST", "/logs/_field_caps"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"fields":{"message":{"keyword":{"searchable":true,"aggregatable":true}}}}"#
                )
            case ("POST", "/logs/_pit"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"id":"pit-id"}"#
                )
            case ("POST", "/_search"), ("POST", "/logs/_search"):
                return try search(request)
            case ("DELETE", "/_pit"):
                return ElasticsearchURLProtocolStub.response(for: request)
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
    }

    private func installCompatibilityHandler(
        host: String,
        version: String,
        pitStatus: Int,
        observation: CompatibilityObservation
    ) {
        ElasticsearchURLProtocolStub.install(for: host) { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    headers: [
                        "Content-Type": "application/json",
                        "X-Elastic-Product": "Elasticsearch",
                    ],
                    json: #"{"version":{"number":"\#(version)"},"tagline":"You Know, for Search"}"#
                )
            case ("GET", "/logs/_mapping"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"logs":{"mappings":{"properties":{"message":{"type":"keyword"}}}}}"#
                )
            case ("POST", "/logs/_field_caps"):
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"fields":{"message":{"keyword":{"searchable":true,"aggregatable":true}}}}"#
                )
            case ("POST", "/logs/_pit"):
                observation.openedPIT.withLock { $0 = true }
                if pitStatus == 403 {
                    return ElasticsearchURLProtocolStub.response(
                        for: request,
                        status: 403,
                        json: #"{"error":{"type":"security_exception","reason":"forbidden"},"status":403}"#
                    )
                }
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    json: #"{"id":"pit-id"}"#
                )
            case ("POST", "/logs/_search"):
                observation.searchBody.withLock {
                    $0 = Self.requestBody(request)
                }
                return Self.searchResponse(request, ids: ["1"])
            default:
                return ElasticsearchURLProtocolStub.response(
                    for: request,
                    status: 404,
                    json: #"{"error":"unexpected request"}"#
                )
            }
        }
    }

    private static func searchResponse(
        _ request: URLRequest,
        ids: [String]
    ) -> (HTTPURLResponse, Data) {
        let hits = ids.enumerated().map { index, id in
            [
                "_id": id,
                "_index": "logs",
                "_score": 1.0,
                "_source": ["message": "row-\(id)"],
                "sort": [Int(id) ?? index],
            ] as [String: Any]
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "pit_id": "pit-id",
            "hits": ["hits": hits],
        ])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
