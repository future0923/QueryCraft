import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

actor MilvusWorkspaceSession: WorkspaceSession, WorkspaceSessionCapabilityProviding, WorkspaceRequestExecutingSession {
    let capabilities = WorkspaceSessionCapabilities.milvus
    private let client: MilvusHTTPClient
    private var connected = false
    private var configurationDatabase: String?

    init(configuration: MilvusConnectionConfiguration, protocolClasses: [AnyClass]? = nil) throws {
        configurationDatabase = configuration.database
        client = try MilvusHTTPClient(configuration: configuration, protocolClasses: protocolClasses)
    }

    func connect() async throws {
        #if !os(iOS)
        try await LicenseAccessGate.shared.requireDatabaseAccess()
        #endif
        _ = try await post("/v2/vectordb/collections/list", body: ["dbName": configurationDatabase ?? "default"])
        connected = true
    }

    func isConnected() async -> Bool { connected }

    func fetchDatabases() async throws -> [String] {
        try requireConnection()
        let response = try await post("/v2/vectordb/databases/list", body: [:])
        let root = try Self.object(response.body)
        guard let names = root["data"] as? [String] else { throw MilvusError.invalidResponse }
        return names.sorted()
    }

    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] {
        try requireConnection()
        let response = try await post("/v2/vectordb/collections/list", body: ["dbName": database])
        let root = try Self.object(response.body)
        guard let names = root["data"] as? [String] else { throw MilvusError.invalidResponse }
        return names.sorted().map { WorkspaceDatabaseObject(name: $0, kind: .milvusCollection) }
    }

    func fetchDetails(for object: WorkspaceDatabaseObject, in database: String) async throws -> WorkspaceDatabaseObjectDetails {
        try requireConnection()
        let response = try await post("/v2/vectordb/collections/describe", body: ["dbName": database, "collectionName": object.name])
        let root = try Self.object(response.body)
        guard let data = root["data"] as? [String: Any],
              let fields = data["fields"] as? [[String: Any]] else { throw MilvusError.invalidResponse }
        let columns = fields.enumerated().map { index, field in
            let name = field["fieldName"] as? String ?? field["name"] as? String ?? "field_\(index)"
            var type = Self.typeName(field["dataType"] ?? field["type"] ?? "unknown")
            let params = field["elementTypeParams"] as? [String: Any] ?? field["params"] as? [String: Any] ?? [:]
            if let dimension = params["dim"] { type += "(\(dimension))" }
            else if let dimension = (field["params"] as? [[String: Any]])?.first(where: { $0["key"] as? String == "dim" })?["value"] { type += "(\(dimension))" }
            let primary = field["primaryKey"] as? Bool ?? field["isPrimaryKey"] as? Bool ?? field["isPrimary"] as? Bool ?? false
            return WorkspaceDatabaseColumn(name: name, type: type, collation: nil, isNullable: field["nullable"] as? Bool ?? false, key: primary ? "PRIMARY" : "", defaultValue: nil, extra: field["autoId"] as? Bool == true ? "AutoID" : "", comment: field["description"] as? String ?? "")
        }
        return WorkspaceDatabaseObjectDetails(columns: columns, ddl: "")
    }

    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] { [] }

    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult {
        try requireConnection()
        guard sort == .none else { throw MilvusError.unsupported("Milvus 数据浏览暂不支持通用表格排序，请使用向量 Search。") }
        guard offset >= 0, limit > 0, offset < 16_383, limit < 16_384 - offset else {
            throw MilvusError.unsupported("Milvus 分页要求 offset + limit 小于 16384。")
        }
        let boundedLimit = limit
        let details = try await fetchDetails(for: object, in: database)
        let response = try await post("/v2/vectordb/entities/query", body: ["dbName": database, "collectionName": object.name, "filter": "", "outputFields": ["*"], "limit": boundedLimit, "offset": offset])
        let root = try Self.object(response.body)
        guard let values = root["data"] as? [[String: Any]] else { throw MilvusError.invalidResponse }
        let schemaKeys = details.columns.map(\.name)
        let keys = schemaKeys + Self.keys(values).filter { !schemaKeys.contains($0) }.sorted()
        let columns = keys.enumerated().map { index, name in
            WorkspaceDatabaseDataColumn(id: index, name: name, type: details.columns.first { $0.name == name }?.type)
        }
        let rows = values.enumerated().map { rowIndex, value in
            WorkspaceDatabaseDataRow(id: max(0, offset) + rowIndex, values: keys.map { Self.cell(value[$0]) })
        }
        await onBatch(WorkspaceDatabaseDataBatch(columns: columns, rows: rows))
        return WorkspaceDatabaseDataFetchResult(columns: columns, hasNextPage: values.count == boundedLimit && offset + boundedLimit * 2 < 16_384)
    }

    func fetchDataCount(for object: WorkspaceDatabaseObject, in database: String) async throws -> Int {
        try requireConnection()
        throw MilvusError.unsupported("Milvus 浏览不提供精确总数。")
    }

    func close() async { await client.close(); connected = false }

    func executeRequest(_ request: WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult {
        try await executeRequest(request, policy: .readOnly)
    }

    func executeRequest(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) async throws -> WorkspaceRequestExecutionResult {
        try requireConnection()
        let validated = try MilvusReadRequest.validate(request, database: configurationDatabase ?? "default")
        let response = try await client.post(validated.path, body: validated.body ?? Data())
        return .init(statusCode: response.statusCode, contentType: "application/json", body: response.body)
    }

    private func requireConnection() throws { guard connected else { throw MilvusError.invalidResponse } }

    private func post(_ path: String, body: [String: Any]) async throws -> MilvusHTTPClient.Response {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await client.post(path, body: data)
    }

    func fetchDataPage(for object: WorkspaceDatabaseObject, in database: String, offset: Int, limit: Int, sort: WorkspaceDatabaseDataSort, filter: WorkspaceDatabaseDataFilter, onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void) async throws -> WorkspaceDatabaseDataFetchResult {
        guard !filter.isActive else { throw MilvusError.unsupported("请使用 Milvus 专用过滤表达式。") }
        return try await fetchDataPage(for: object, in: database, offset: offset, limit: limit, sort: sort, onBatch: onBatch)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MilvusError.invalidResponse }
        return root
    }

    private static func keys(_ rows: [[String: Any]]) -> [String] {
        var result: [String] = []
        for row in rows { for key in row.keys where !result.contains(key) { result.append(key) } }
        return result
    }

    private static func cell(_ value: Any?) -> WorkspaceDatabaseDataCell {
        guard let value else { return .null }
        if value is NSNull { return .null }
        if let string = value as? String { return .text(string) }
        if let number = value as? NSNumber { return .text(number.stringValue) }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return .text(String(describing: value)) }
        return .text(text)
    }

    private static func typeName(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            return [1: "Bool", 2: "Int8", 3: "Int16", 4: "Int32", 5: "Int64", 10: "Float", 11: "Double", 20: "String", 21: "VarChar", 22: "Array", 23: "JSON", 100: "BinaryVector", 101: "FloatVector", 102: "Float16Vector", 103: "BFloat16Vector", 104: "SparseFloatVector", 105: "Int8Vector"][number.intValue] ?? number.stringValue
        }
        return String(describing: value)
    }
}
