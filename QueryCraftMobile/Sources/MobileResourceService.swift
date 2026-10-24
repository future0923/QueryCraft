import Foundation
import QueryCraftMobileCore

struct MobileResource: Identifiable, Equatable, Sendable {
    let name: String
    let kind: String
    var binaryKeyData: Data? = nil
    var id: String { kind + "\0" + (binaryKeyData?.base64EncodedString() ?? name) }
}
struct MobileResourceCatalog: Sendable {
    let resources: [MobileResource]
    var cursor: UInt64 = 0
}
struct MobileResourceDetails: Sendable {
    let data: MobileGridData
    let structure: MobileGridData
    let status: String
    var hasNext = false
    var nextCursor: UInt64 = 0
    var pageStride = 100
    var redisType: RedisKeyType? = nil
}
protocol MobileResourceServicing: Sendable {
    func scopes() async throws -> [String]
    func catalog(scope: String, cursor: UInt64, search: String) async throws -> MobileResourceCatalog
    func details(resource: MobileResource, scope: String, offset: Int, cursor: UInt64) async throws -> MobileResourceDetails
}

struct MobileResourceService: MobileResourceServicing {
    let profile: MobileConnectionProfile
    let password: String?
    private let streamCursors = MobileRedisStreamCursorStore()
    init(profile: MobileConnectionProfile, password: String?) { self.profile = profile; self.password = password }
    private func redis() throws -> RedisClient {
        guard profile.tlsMode == .disabled else { throw RedisWorkspaceError.unsupportedTLS }
        guard let index = RedisConnectionConfiguration.databaseIndex(from: profile.database) else { throw MobileQueryError.invalidConnection }
        return RedisClient(configuration: .init(host: profile.host, port: profile.port, username: profile.username, password: password, databaseIndex: index))
    }
    private func elasticsearch() throws -> ElasticsearchHTTPClient {
        let auth: DatabaseConnectionAuthentication = switch profile.authentication {
        case .usernamePassword: .usernamePassword(username: profile.username, password: password)
        case .apiKey: .apiKey(password)
        case .none: .none
        }
        return try ElasticsearchHTTPClient(configuration: .init(host: profile.host, port: profile.port, authentication: auth, tlsMode: profile.tlsMode))
    }
    func test() async throws {
        if profile.driver == .redis {
            let client = try redis()
            do { try await client.connect(); _ = try await client.execute(["PING"]); await client.close(); try Task.checkCancellation() }
            catch { await client.close(); throw error }
        } else {
            let client = try elasticsearch()
            do {
                let response = try await client.perform(method: .get, path: "/")
                _ = try ElasticsearchServerIdentity.version(body: response.body, headers: response.headers)
                await client.close()
            } catch { await client.close(); throw error }
        }
    }
    func scopes() async throws -> [String] {
        if profile.driver == .elasticsearch { try await test(); return ["Elasticsearch"] }
        let client = try redis()
        do {
            try await client.connect()
            let cluster = try await client.execute(["INFO", "cluster"])
            let keyspace = try? await client.execute(["INFO", "keyspace"])
            let counts = RedisKeyspaceInfoParser.parse(keyspace?.stringValue ?? "")
            let config = try? await client.execute(["CONFIG", "GET", "databases"])
            let configured: Int? = config.flatMap { reply in
                if case .map(let entries) = reply { return entries.first { $0.key.stringValue == "databases" }?.value.integerValue.flatMap(Int.init(exactly:)) }
                return reply.collectionValues?.last?.integerValue.flatMap(Int.init(exactly:))
            }
            await client.close(); try Task.checkCancellation()
            if cluster.stringValue?.contains("cluster_enabled:1") == true { return ["0"] }
            let count = max(configured ?? 16, (counts.keys.max() ?? -1) + 1, 1)
            guard count <= 10_000 else { throw MobileQueryError.resultTooLarge }
            return (0..<count).map(String.init)
        } catch { await client.close(); throw error }
    }
    func catalog(scope: String, cursor: UInt64, search: String) async throws -> MobileResourceCatalog {
        if profile.driver == .redis {
            let client = try redis()
            do {
                try await client.connect()
                let reply = try await client.executeRaw(RedisScanCodec.arguments(cursor: cursor, pattern: search, count: 100).map { .init(utf8: $0) }, databaseIndex: Int(scope))
                let page = try RedisScanCodec.page(reply.redisReplyValue, databaseIndex: Int(scope) ?? 0)
                guard let values = reply.collectionValues, values.count == 2,
                      let rawKeys = values[1].collectionValues, rawKeys.count == page.keys.count else { throw RedisWorkspaceError.invalidReply("SCAN") }
                let resources = zip(page.keys, rawKeys).map { reference, raw -> MobileResource in
                    if let bytes = raw.dataValue, String(data: bytes, encoding: .utf8) == nil {
                        return .init(name: "HEX: " + RedisHexCodec.format(bytes), kind: "二进制键名（暂不支持）", binaryKeyData: bytes)
                    }
                    return .init(name: reference.name, kind: "key")
                }
                await client.close(); try Task.checkCancellation()
                return .init(resources: resources, cursor: page.nextCursor)
            } catch { await client.close(); throw error }
        }
        let client = try elasticsearch()
        do {
            let response = try await client.perform(method: .get, path: "/_resolve/index/*?expand_wildcards=all", maximumResponseBytes: 8_388_608)
            guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw ElasticsearchError.invalidResponse }
            var resources: [MobileResource] = []
            for (key, kind) in [("indices", "索引"), ("aliases", "别名"), ("data_streams", "数据流")] {
                for object in root[key] as? [[String: Any]] ?? [] {
                    guard let name = object["name"] as? String else { throw ElasticsearchError.invalidResponse }
                    resources.append(.init(name: name, kind: kind))
                }
            }
            guard resources.count <= 10_000 else { throw MobileQueryError.resultTooLarge }
            await client.close(); try Task.checkCancellation()
            return .init(resources: resources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch { await client.close(); throw error }
    }
    func details(resource: MobileResource, scope: String, offset: Int, cursor: UInt64) async throws -> MobileResourceDetails {
        if resource.binaryKeyData != nil { throw MobileRedisMutationError.unsupportedBinaryKey }
        if profile.driver == .redis { return try await redisDetails(resource: resource, scope: scope, offset: offset, cursor: cursor) }
        guard offset >= 0, offset <= 9_900 else { throw ElasticsearchError.deepPageUnavailable }
        let client = try elasticsearch(), path = Self.pathComponent(resource.name)
        do {
            let body = try JSONSerialization.data(withJSONObject: ["from": offset, "size": 100, "query": ["match_all": [:]], "sort": ["_doc"], "track_total_hits": true] as [String: Any])
            let response = try await client.perform(method: .post, path: "/\(path)/_search", body: body, maximumResponseBytes: 8_388_608, enforceReadOnlyPolicy: true)
            let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            guard root?["timed_out"] as? Bool != true,
                  ((root?["_shards"] as? [String: Any])?["failed"] as? Int ?? 0) == 0,
                  let hits = (root?["hits"] as? [String: Any])?["hits"] as? [[String: Any]] else { throw ElasticsearchError.invalidResponse }
            let rows: [[String?]] = hits.map { hit in
                let source = hit["_source"].map { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) } ?? nil
                return [hit["_id"] as? String, hit["_index"] as? String, source.map { String(decoding: $0, as: UTF8.self) }]
            }
            let mappings = try await client.perform(method: .get, path: "/\(path)/_mapping", maximumResponseBytes: 8_388_608)
            let caps = try await client.perform(method: .get, path: "/\(path)/_field_caps?fields=*", maximumResponseBytes: 8_388_608)
            let fields = try ElasticsearchMappingCatalog.parse(mappingData: mappings.body, fieldCapsData: caps.body).fields
            let total = (root?["hits"] as? [String: Any])?["total"]
            let count = (total as? [String: Any])?["value"] as? Int ?? total as? Int
            await client.close(); try Task.checkCancellation()
            return .init(data: .init(columns: ["_id", "_index", "_source"], rows: rows),
                structure: .init(columns: ["字段", "类型", "可搜索", "可聚合", "类型冲突"], rows: fields.map { [$0.path, $0.type, $0.isSearchable ? "是" : "否", $0.isAggregatable ? "是" : "否", $0.hasTypeConflict ? "是" : "否"] }),
                status: rows.isEmpty ? "只读 · 没有文档" : "只读 · 第 \(offset + 1)–\(offset + rows.count) 条 · 最多浏览前 10,000 条；并发写入可能影响分页",
                hasNext: offset + 100 < min(count ?? Int.max, 10_000) && rows.count == 100)
        } catch { await client.close(); throw error }
    }
    private func redisDetails(resource: MobileResource, scope: String, offset: Int, cursor: UInt64) async throws -> MobileResourceDetails {
        let client = try redis(), key = resource.name
        do {
            try await client.connect()
            func command(_ args: [String]) async throws -> RedisReplyValue {
                let reply = try await client.execute(args, databaseIndex: Int(scope))
                if case .error(let message) = reply { throw RedisClientError(message: message) }
                try Task.checkCancellation(); return reply
            }
            var type = try await command(["TYPE", key]).stringValue ?? "unknown"
            var ttl = try await command(["PTTL", key]).integerValue
            var next: UInt64 = 0, hasNext = false
            var rows: [[String?]] = []
            switch type {
            case "string":
                let total = try await command(["STRLEN", key]).integerValue ?? 0
                let raw = try await client.executeRaw(["GETRANGE", key, String(offset), String(offset + 65_535)].map(RedisBinaryValue.init(utf8:)), databaseIndex: Int(scope))
                guard let data = raw.dataValue else { throw RedisWorkspaceError.invalidReply("GETRANGE") }
                rows = [[String(offset), String(data: data, encoding: .utf8) ?? "BINARY (\(data.count) bytes): " + data.prefix(256).map { String(format: "%02x", $0) }.joined()]]
                hasNext = offset + 65_536 < total
            case "list", "hash", "set", "zset":
                let reference = RedisKeyReference(databaseIndex: Int(scope) ?? 0, name: key, type: RedisKeyType(rawValue: type) ?? .unknown)
                let identity = "collection\0" + scope + "\0" + key + "\0" + type
                let continuation = try await streamCursors.resolve(cursor, identity: identity).map(RedisCollectionContinuation.init(rawValue:))
                let page = try await RedisCollectionReader(client: client).fetchRedisCollectionPage(.init(reference: reference, continuation: continuation, limit: 100))
                func display(_ value: RedisBinaryValue) -> String {
                    value.losslessUTF8String ?? "HEX: " + RedisHexCodec.format(value.data)
                }
                rows = page.entries.map { entry in
                    switch entry {
                    case .list(let index, let value): [String(index), display(value)]
                    case .hash(let field, let value, _): [display(field), display(value)]
                    case .set(let member): [display(member), nil]
                    case .sortedSet(let member, let score): [display(member), score]
                    }
                }
                hasNext = page.hasMore
                if let continuation = page.continuation, page.hasMore { next = await streamCursors.save(continuation.rawValue, identity: identity) }
            case "stream":
                let identity = scope + "\0" + key
                let after = try await streamCursors.resolve(cursor, identity: identity)
                let page = try await RedisStreamReader.read(client: client, reference: .init(databaseIndex: Int(scope) ?? 0, name: key, type: .stream), afterID: after, limit: 100)
                rows = page.rows.map { $0.map(Optional.some) }; hasNext = page.hasMore
                if let id = page.lastID, page.hasMore { next = await streamCursors.save(id, identity: identity) }
            case "none": rows = []
            default: throw RedisWorkspaceError.unsupportedKeyType(type)
            }
            let finalType = try await command(["TYPE", key]).stringValue
            if finalType == "none" { type = "none"; ttl = -2; rows = []; hasNext = false; next = 0 }
            else if finalType != type { throw RedisWorkspaceError.mutationConflict(key) }
            let memory = try? await command(["MEMORY", "USAGE", key]).integerValue
            let encoding = try? await command(["OBJECT", "ENCODING", key]).stringValue
            guard rows.count <= 10_000, rows.flatMap({ $0 }).reduce(0, { $0 + ($1?.utf8.count ?? 0) }) <= 8_388_608 else { throw MobileQueryError.resultTooLarge }
            await client.close(); try Task.checkCancellation()
            let columns: [String]
            switch type {
            case "hash": columns = ["字段", "值"]
            case "zset": columns = ["成员", "分数"]
            case "stream": columns = ["entryID", "fields"]
            default: columns = ["位置 / 成员", "值"]
            }
            let attributes: [[String?]] = [
                ["类型", type], ["PTTL（毫秒）", ttl.map(String.init)],
                ["MEMORY USAGE（字节）", memory.map(String.init) ?? "不可用"],
                ["编码", encoding ?? "不可用"], ["说明", "-1 无过期时间；-2 键已不存在"]
            ]
            let status = type == "none" ? "键已不存在" : "\(type) · \(rows.count) 项；SCAN COUNT 为提示值"
            return MobileResourceDetails(data: .init(columns: columns, rows: rows), structure: .init(columns: ["属性", "值"], rows: attributes), status: status, hasNext: hasNext, nextCursor: next, pageStride: type == "string" ? 65_536 : 100, redisType: RedisKeyType(rawValue: type))

        } catch { await client.close(); throw error }
    }
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? ""
    }
    static func display(_ reply: RedisReplyValue) -> String {
        reply.stringValue ?? (reply == .null ? "NULL" : String(describing: reply))
    }
}

private actor MobileRedisStreamCursorStore {
    struct Entry { let identity: String; let id: String }
    private var sequence: UInt64 = 0
    private var entries: [UInt64: Entry] = [:]
    func resolve(_ token: UInt64, identity: String) throws -> String? {
        if token == 0 { return nil }
        guard let entry = entries[token], entry.identity == identity else { throw RedisWorkspaceError.invalidReply("Stream cursor expired; reopen the key") }
        return entry.id
    }
    func save(_ id: String, identity: String) -> UInt64 {
        sequence &+= 1; entries[sequence] = .init(identity: identity, id: id)
        if entries.count > 1_000 { entries.removeValue(forKey: sequence - 1_000) }
        return sequence
    }
}
