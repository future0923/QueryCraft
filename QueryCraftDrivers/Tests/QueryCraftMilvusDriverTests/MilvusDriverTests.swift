import Testing
import Foundation
import Synchronization
import QueryCraftFeature
@testable import QueryCraftMilvusDriver

@Test("Milvus driver target is available")
func milvusDriverTargetIsAvailable() {
    #expect(MilvusDatabaseDriver().databaseType.rawValue == "milvus")
}

@Test("Milvus executes bounded REST reads and rejects writes before transport")
func milvusReadRequestTransport() async throws {
    let host = "rest-read.local"
    let seen = Mutex<[String]>([])
    MilvusURLProtocolStub.install(for: host) { request in
        let path = request.url?.path ?? ""
        seen.withLock { $0.append(path) }
        if path == "/v2/vectordb/collections/list" {
            return MilvusURLProtocolStub.response(for: request, json: #"{"code":0,"data":["items"]}"#)
        }
        return MilvusURLProtocolStub.response(for: request, json: #"{"code":0,"data":[{"id":"9223372036854775807","distance":0.9}]}"#)
    }
    defer { MilvusURLProtocolStub.reset(host: host) }
    let session = try MilvusWorkspaceSession(configuration: .init(.init(databaseType: .milvus, host: host,
        port: 19530, authentication: .none, database: "default", tlsMode: .disabled)), protocolClasses: [MilvusURLProtocolStub.self])
    try await session.connect()
    for (operation, body) in [("query", "{}"), ("get", #"{"id":["9223372036854775807"]}"#), ("search", #"{"data":[[0.1,0.2]],"annsField":"embedding"}"#)] {
        let request = try MilvusReadRequest.make(operation: operation, database: "default", collection: "items", body: Data(body.utf8), maximumRows: 2)
        let result = try await session.executeRequest(request, policy: .readOnly)
        #expect(result.statusCode == 200)
        #expect(String(decoding: result.body, as: UTF8.self).contains("9223372036854775807"))
    }
    for (path, body) in [("/v2/vectordb/entities/delete", #"{"collectionName":"items"}"#),
                         ("/v2/vectordb/entities/query", #"{"dbName":"private","collectionName":"items"}"#)] {
        await #expect(throws: (any Error).self) {
            _ = try await session.executeRequest(.init(method: .post, path: path, body: Data(body.utf8)), policy: .writesAllowed)
        }
    }
    #expect(seen.withLock { $0.count } == 4)
    await session.close()
}

@Test("Milvus uses raw Bearer credentials and retains Int64 values")
func milvusAuthentication() async throws {
    let auths: [DatabaseConnectionAuthentication] = [.usernamePassword(username: "root", password: "secret"), .apiKey("key"), .none]
    for (index, auth) in auths.enumerated() {
        let host = "auth-\(index).local", seen = Mutex<String?>(nil)
        MilvusURLProtocolStub.install(for: host) { request in
            seen.withLock { $0 = request.value(forHTTPHeaderField: "Authorization") }
            #expect(request.value(forHTTPHeaderField: "Accept-Type-Allow-Int64") == "true")
            #expect(request.httpMethod == "POST")
            return MilvusURLProtocolStub.response(for: request, json: #"{"code":0,"data":["default"]}"#)
        }
        defer { MilvusURLProtocolStub.reset(host: host) }
        let config = DatabaseConnectionConfiguration(databaseType: .milvus, host: host, port: 19530, authentication: auth, database: "default", tlsMode: .disabled)
        let client = try MilvusHTTPClient(configuration: .init(config), protocolClasses: [MilvusURLProtocolStub.self])
        _ = try await client.post("/v2/vectordb/databases/list", body: Data("{}".utf8))
        #expect(seen.withLock { $0 } == ["Bearer root:secret", "Bearer key", nil][index])
        await client.close()
    }
}

@Test("Milvus rejects server errors and malformed success envelopes")
func milvusServerErrors() async throws {
    for (index, json) in [#"{"code":1800,"message":"denied"}"#, #"{"data":[]}"#].enumerated() {
        let host = "error-\(index).local"
        MilvusURLProtocolStub.install(for: host) { MilvusURLProtocolStub.response(for: $0, json: json) }
        defer { MilvusURLProtocolStub.reset(host: host) }
        let config = DatabaseConnectionConfiguration(databaseType: .milvus, host: host, port: 19530, authentication: .none, database: nil, tlsMode: .disabled)
        let client = try MilvusHTTPClient(configuration: .init(config), protocolClasses: [MilvusURLProtocolStub.self])
        await #expect(throws: MilvusError.self) { _ = try await client.post("/v2/vectordb/databases/list", body: Data("{}".utf8)) }
        await client.close()
    }
}

private actor MilvusBatchSink {
    var value: WorkspaceDatabaseDataBatch?
    func receive(_ batch: WorkspaceDatabaseDataBatch) { value = batch }
}

@Test("Collection schema, vector dimension, empty rows and dynamic columns")
func milvusBrowse() async throws {
    let host = "browse.local", sink = MilvusBatchSink()
    MilvusURLProtocolStub.install(for: host) { request in
        let json: String
        switch request.url?.path {
        case "/v2/vectordb/collections/list": json = #"{"code":0,"data":["items"]}"#
        case "/v2/vectordb/databases/list": json = #"{"code":0,"data":["default"]}"#
        case "/v2/vectordb/collections/describe":
            json = #"{"code":0,"data":{"fields":[{"name":"id","type":5,"primaryKey":true},{"name":"embedding","type":101,"params":[{"key":"dim","value":"1024"}]}]}}"#
        case "/v2/vectordb/entities/query":
            json = #"{"code":0,"data":[{"id":"9007199254740993","embedding":[0.1,0.2],"extra":{"ok":true}}]}"#
        default: throw URLError(.badURL)
        }
        return MilvusURLProtocolStub.response(for: request, json: json)
    }
    defer { MilvusURLProtocolStub.reset(host: host) }
    let config = DatabaseConnectionConfiguration(databaseType: .milvus, host: host, port: 19530, authentication: .none, database: nil, tlsMode: .disabled)
    let session = try MilvusWorkspaceSession(configuration: .init(config), protocolClasses: [MilvusURLProtocolStub.self])
    try await session.connect()
    #expect(try await session.fetchDatabases() == ["default"])
    let object = try #require(try await session.fetchObjects(in: "default").first)
    #expect(object.kind == .milvusCollection)
    let schema = try await session.fetchDetails(for: object, in: "default")
    #expect(schema.columns.map(\.type) == ["Int64", "FloatVector(1024)"])
    #expect(schema.columns.first?.key == "PRIMARY")
    _ = try await session.fetchDataPage(for: object, in: "default", offset: 0, limit: 100, sort: .none) { await sink.receive($0) }
    let batch = try #require(await sink.value)
    #expect(batch.columns.map(\.name) == ["id", "embedding", "extra"])
    #expect(batch.rows.first?.values.first == .text("9007199254740993"))
    await #expect(throws: MilvusError.self) {
        _ = try await session.fetchDataPage(for: object, in: "default", offset: 16300, limit: 100, sort: .none) { _ in }
    }
    await session.close()
}
