import Foundation
import Testing
@testable import QueryCraftFeature

struct MCPMilvusTests {
    @Test func requestsBindIdentitiesAndClampQueryLimit() throws {
        let request = try MilvusReadRequest.make(operation: "query", database: "default", collection: "items",
            body: Data(#"{"filter":"price > 10","limit":1000,"offset":5,"outputFields":["id","price"]}"#.utf8), maximumRows: 12)
        let requestBody = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(request.path == "/v2/vectordb/entities/query")
        #expect(body["dbName"] as? String == "default")
        #expect(body["collectionName"] as? String == "items")
        #expect(body["limit"] as? Int == 12)
        #expect(body["offset"] as? Int == 5)
        #expect(body["filter"] as? String == "price > 10")
    }

    @Test(arguments: [#"{"dbName":"private"}"#, #"{"collectionName":"private"}"#,
                      #"{"limit":true}"#, #"{"offset":-1}"#, #"{"offset":16383}"#,
                      #"{"offset":16380,"limit":4}"#, #"{"filter":{"$ref":"private"}}"#])
    func rejectsInvalidScopeAndPagination(_ body: String) {
        #expect(throws: (any Error).self) {
            try MilvusReadRequest.make(operation: "query", database: "default", collection: "items", body: Data(body.utf8), maximumRows: 100)
        }
    }

    @Test(arguments: ["insert", "upsert", "delete", "query?x=1", "../collections/drop", "query/", "https://example.com"])
    func driverReadAllowlistRejectsWritesAndRoutes(_ operation: String) {
        let request = WorkspaceRequest(method: .post, path: "/v2/vectordb/entities/" + operation,
            body: Data(#"{"dbName":"default","collectionName":"items"}"#.utf8))
        #expect(throws: (any Error).self) { try MilvusReadRequest.validate(request, database: "default") }
    }

    @Test func searchAndGetRetainNativeParametersAndLargeIDs() throws {
        for (operation, body) in [
            ("search", #"{"data":[[0.1,0.2]],"annsField":"embedding","searchParams":{"metricType":"COSINE"},"limit":10}"#),
            ("get", #"{"id":["9223372036854775807"],"outputFields":["id","embedding"]}"#)
        ] {
            let request = try MilvusReadRequest.make(operation: operation, database: "default", collection: "items", body: Data(body.utf8), maximumRows: 2)
            #expect(try MilvusReadRequest.validate(request, database: "default") == request)
        }
        for body in [#"{"data":[[1],[2]]}"#, #"{"data":[[1]],"ids":[1]}"#, #"{"ids":[true]}"#, #"{"data":[[1]],"groupSize":3}"#] {
            #expect(throws: (any Error).self) {
                try MilvusReadRequest.make(operation: "search", database: "default", collection: "items", body: Data(body.utf8), maximumRows: 2)
            }
        }
    }

    @Test func runtimeEnforcesScopeAndReturnsReadResults() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MilvusMCPTestSession()
        let runtime = MCPRuntime(directory: root, registry: DatabaseDriverRegistry(drivers: [MilvusMCPTestDriver(session: session)]))
        let profile = ConnectionProfile(id: UUID(), name: "Milvus test", groupID: nil, databaseType: .milvus,
            host: "localhost", port: 19530, username: "root", defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: Date())
        try await runtime.repository.insert(profile)
        var policy = MCPPolicy()
        policy.enabled = true
        policy.allConnections = true
        policy.maximumRows = 2
        policy.connections[profile.id.uuidString] = .init(databases: ["default"], mode: .readOnly)
        try MCPPolicyStore(directory: root).save(policy)
        var args: [String: MCPJSONValue] = ["connection_id": .string(profile.id.uuidString), "collection": "items",
            "operation": "query", "body": #"{"limit":1000}"#]
        let value = try await runtime.call("querycraft_execute_milvus_request", arguments: args)
        #expect(value.objectValue?["returned_entities"] == .int(1))
        #expect(value.objectValue?["body"]?.stringValue?.contains("9223372036854775807") == true)
        let request = try #require(await session.requests.first)
        let requestBody = try #require(request.body)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["dbName"] as? String == "default")
        #expect(body["limit"] as? Int == 2)
        args["database"] = "private"
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_execute_milvus_request", arguments: args) }
        args["database"] = "default"
        args["body"] = #"{"dbName":"private"}"#
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_execute_milvus_request", arguments: args) }
        args["body"] = "{}"
        args["collection"] = "missing"
        await #expect(throws: MCPFailure.self) { _ = try await runtime.call("querycraft_execute_milvus_request", arguments: args) }
        #expect(await session.requests.count == 1)
        policy.connections[profile.id.uuidString] = .init(databases: ["allowed"], mode: .readOnly)
        try MCPPolicyStore(directory: root).save(policy)
        let databases = try await runtime.call("querycraft_list_databases", arguments: ["connection_id": .string(profile.id.uuidString)])
        #expect(databases == .array(["allowed"]))
        #expect(await session.connectedDatabases.last == "allowed")
        #expect(MCPToolCatalog.driverTools(.milvus).contains("execute_milvus_request"))
        #expect(MCPToolCatalog.readTools.contains("execute_milvus_request"))
        await runtime.shutdown()
    }
}

private struct MilvusMCPTestDriver: DatabaseDriver {
    let databaseType = DatabaseType.milvus
    let session: MilvusMCPTestSession
    func makeSession(configuration: DatabaseConnectionConfiguration) async throws -> any WorkspaceSession {
        await session.recordDatabase(configuration.database)
        return session
    }
    func testConnection(configuration: DatabaseConnectionConfiguration) async throws {}
}

private actor MilvusMCPTestSession: WorkspaceSession, WorkspaceRequestExecutingSession {
    var requests: [WorkspaceRequest] = []
    var connectedDatabases: [String] = []
    func recordDatabase(_ database: String?) { connectedDatabases.append(database ?? "") }
    func connect() async throws {}
    func close() async {}
    func isConnected() async -> Bool { true }
    func fetchDatabases() async throws -> [String] { ["default", "allowed"] }
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] { [.init(name: "items", kind: .milvusCollection)] }
    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails { .init(columns: [], ddl: "") }
    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }
    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int { 0 }
    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort,
                       onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult { .init(columns: [], hasNextPage: false) }
    func executeRequest(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult {
        requests.append(request)
        return .init(statusCode: 200, contentType: "application/json", body: Data(#"{"code":0,"data":[{"id":"9223372036854775807"}]}"#.utf8))
    }
    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        try await executeRequest(request)
    }
}
