import Foundation
import QueryCraftMobileCore

struct MobileRedisSnapshot: Sendable {
    let details: RedisKeyDetails
    let stringData: RedisBinaryValue?
    let rows: [RedisKeyEditableRow]
    let count: Int
    var hashFieldExpirationSupport: Bool? = false
    var matchingCount: Int? = nil
    var scannedCount: Int = 0
    var isPartial = false
    var continuation: RedisCollectionContinuation? = nil

    // Whole-key operations (TTL/delete) must not apply to a replaced key.
    // Value edits use the shared Mac planner's member-level assertions.
    var assertions: [RedisMutationAssertion] {
        var result: [RedisMutationAssertion] = [.keyType(details.reference.type), .elementCount(count)]
        if let stringData { result.append(.stringValue(stringData)) }
        for row in rows {
            switch details.reference.type {
            case .list: result.append(.listElement(index: row.originalIndex!, value: row.originalSecondData))
            case .hash: result.append(.hashValue(field: row.originalFirstData, value: row.originalSecondData))
            case .set: result.append(.setMembership(member: row.originalFirstData, exists: true))
            case .sortedSet: result.append(.sortedSetScore(member: row.originalFirstData, score: row.originalSecondValue))
            default: break
            }
        }
        return result
    }
}

protocol MobileRedisMutating: Sendable {
    func load(key: String, database: Int) async throws -> MobileRedisSnapshot?
    func loadPage(key: String, database: Int, continuation: RedisCollectionContinuation?) async throws -> MobileRedisSnapshot?
    func searchPage(key: String, database: Int, continuation: RedisCollectionContinuation?, search: RedisCollectionSearch?) async throws -> MobileRedisSnapshot?
    func apply(_ request: RedisOptimisticMutationRequest) async throws
}

extension MobileRedisMutating {
    func loadPage(key: String, database: Int, continuation: RedisCollectionContinuation?) async throws -> MobileRedisSnapshot? {
        try await load(key: key, database: database)
    }
    func searchPage(key: String, database: Int, continuation: RedisCollectionContinuation?, search: RedisCollectionSearch?) async throws -> MobileRedisSnapshot? {
        guard search == nil else { throw MobileRedisMutationError.unsupported }
        return try await loadPage(key: key, database: database, continuation: continuation)
    }

}

enum MobileRedisMutationError: LocalizedError {
    case unsupported, unsupportedBinaryKey, tooLarge, unverified(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedBinaryKey: "二进制键名暂不支持移动端读取和编辑。"
        case .unsupported: "此类型暂不支持移动端编辑。"
        case .tooLarge: "集合单页编辑限 1,000 个成员/1 MiB；String 整值编辑限 100 MiB。超限请使用只读分段浏览或外部工具。"
        case .unverified(let message): "提交结果尚未核实，部分命令可能已经生效。请重新读取核实，不能直接重试。\n" + message
        }
    }
}

struct MobileRedisMutationService: MobileRedisMutating {
    let profile: MobileConnectionProfile
    let password: String?
    private func client(database: Int) throws -> RedisClient {
        guard profile.driver == .redis, profile.tlsMode == .disabled, database >= 0 else { throw MobileRedisMutationError.unsupported }
        return RedisClient(configuration: .init(host: profile.host, port: profile.port, username: profile.username, password: password, databaseIndex: database))
    }

    func load(key: String, database: Int) async throws -> MobileRedisSnapshot? {
        let client = try client(database: database)
        do {
            try await client.connect()
            let snapshot = try await read(client, key: key, database: database)
            await client.close(); return snapshot
        } catch { await client.close(); throw error }
    }

    func loadPage(key: String, database: Int, continuation: RedisCollectionContinuation?) async throws -> MobileRedisSnapshot? {
        try await searchPage(key: key, database: database, continuation: continuation, search: nil)
    }
    func searchPage(key: String, database: Int, continuation: RedisCollectionContinuation?, search: RedisCollectionSearch?) async throws -> MobileRedisSnapshot? {
        let client = try client(database: database)
        do {
            try await client.connect()
            let result = try await page(client: client, key: key, database: database, continuation: continuation, search: search)
            await client.close(); return result
        } catch { await client.close(); throw error }
    }
    private func page(client: RedisClient, key: String, database: Int, continuation: RedisCollectionContinuation?, search: RedisCollectionSearch? = nil) async throws -> MobileRedisSnapshot? {
        let typeReply = try await client.execute(["TYPE", key])
        guard let type = typeReply.stringValue.flatMap(RedisKeyType.init(rawValue:)) else { throw RedisWorkspaceError.invalidReply("TYPE") }
        if type == .none { return nil }
        let reference = RedisKeyReference(databaseIndex: database, name: key, type: type)
        let page = try await RedisCollectionReader(client: client, searchBatchSize: 200).fetchRedisCollectionPage(.init(reference: reference, continuation: continuation, limit: 200, search: search))
        var rows: [RedisKeyEditableRow] = []
        for entry in page.entries {
            let first: RedisBinaryValue, second: RedisBinaryValue, index: Int?, ttl: String
            switch entry {
            case .list(let i, let value): first = .init(utf8: String(i)); second = value; index = i; ttl = ""
            case .hash(let field, let value, let milliseconds): first = field; second = value; index = nil; ttl = milliseconds.map(String.init) ?? ""
            case .set(let member): first = member; second = .init(utf8: ""); index = nil; ttl = ""
            case .sortedSet(let member, let score): first = member; second = .init(utf8: score); index = nil; ttl = ""
            }
            rows.append(.init(isNew: false, firstValue: first.losslessUTF8String ?? "HEX: " + RedisHexCodec.format(first.data), secondValue: second.losslessUTF8String ?? "HEX: " + RedisHexCodec.format(second.data), thirdValue: ttl, originalFirstData: first, originalSecondData: second, originalIndex: index, isBinaryReadOnly: first.losslessUTF8String == nil || second.losslessUTF8String == nil))
        }
        guard rows.count <= 1_000, rows.reduce(0, { $0 + $1.originalFirstData.data.count + $1.originalSecondData.data.count }) <= 1_048_576 else { throw MobileRedisMutationError.tooLarge }
        var support: Bool? = page.supportsHashFieldExpiration
        if type == .hash, !page.supportsHashFieldExpiration { support = try? await RedisHashFieldExpirationReader.support(client: client) }
        let ttlReply = try await client.execute(["PTTL", key])
        guard let ttl = ttlReply.integerValue else { throw RedisWorkspaceError.invalidReply("PTTL") }
        if ttl == -2 { return nil }
        guard try await client.execute(["TYPE", key]).stringValue == type.rawValue else { throw RedisWorkspaceError.mutationConflict(key) }
        try Task.checkCancellation()
        return .init(details: .init(reference: reference, ttlMilliseconds: ttl < 0 ? nil : ttl, memoryUsageBytes: nil, encoding: nil, value: .init(columns: [], rows: [], isTruncated: false)), stringData: nil, rows: rows, count: page.totalCount, hashFieldExpirationSupport: support, matchingCount: page.matchingCount, scannedCount: page.scannedCount, isPartial: search != nil || continuation != nil || page.hasMore, continuation: page.continuation)
    }
    private func read(_ client: RedisClient, key: String, database: Int) async throws -> MobileRedisSnapshot? {
        func command(_ arguments: [String]) async throws -> RedisRawReplyValue {
            try Task.checkCancellation()
            let reply = try await client.executeRaw(arguments.map { .init(utf8: $0) })
            if case .error(let message) = reply { throw RedisClientError(message: message) }
            try Task.checkCancellation(); return reply
        }
        let type = RedisKeyType(rawValue: try await command(["TYPE", key]).stringValue ?? "") ?? .unknown
        if type == .none { return nil }
        let countCommand: String
        switch type {
        case .string: countCommand = "STRLEN"
        case .list: countCommand = "LLEN"
        case .hash: countCommand = "HLEN"
        case .set: countCommand = "SCARD"
        case .sortedSet: countCommand = "ZCARD"
        default: throw MobileRedisMutationError.unsupported
        }
        let count = Int(try await command([countCommand, key]).integerValue ?? -1)
        if type != .string, count > 1_000 { return try await page(client: client, key: key, database: database, continuation: nil) }
        guard count >= 0, count <= (type == .string ? RedisStringEditingLimit.maximumBytes : 1_000) else { throw MobileRedisMutationError.tooLarge }
        var string: RedisBinaryValue?, rows: [RedisKeyEditableRow] = [], seen = Set<Data>(), bytes = 0
        func append(_ first: Data, _ second: Data = Data(), index: Int? = nil) throws {
            bytes += first.count + second.count
            guard rows.count < 1_000, bytes <= 1_048_576 else { throw MobileRedisMutationError.tooLarge }
            let a = String(data: first, encoding: .utf8), b = String(data: second, encoding: .utf8)
            rows.append(.init(isNew: false, firstValue: a ?? "HEX: " + RedisHexCodec.format(first), secondValue: b ?? "HEX: " + RedisHexCodec.format(second), originalFirstData: .init(data: first), originalSecondData: .init(data: second), originalIndex: index, isBinaryReadOnly: a == nil || b == nil))
        }
        if type == .string {
            // Bounded even if the value grows after STRLEN.
            let reply = try await command(["GETRANGE", key, "0", String(RedisStringEditingLimit.maximumBytes)])
            guard let data = reply.dataValue, data.count <= RedisStringEditingLimit.maximumBytes else { throw MobileRedisMutationError.tooLarge }
            string = .init(data: data)
        } else if type == .list {
            for offset in stride(from: 0, to: count, by: 100) {
                let reply = try await command(["LRANGE", key, String(offset), String(min(count - 1, offset + 99))])
                for (index, value) in (reply.collectionValues ?? []).enumerated() {
                    guard let data = value.dataValue else { throw RedisWorkspaceError.invalidReply("LRANGE") }
                    try append(Data(String(offset + index).utf8), data, index: offset + index)
                }
            }
        } else {
            var cursor: UInt64 = 0, iterations = 0
            let scan = type == .hash ? "HSCAN" : type == .set ? "SSCAN" : "ZSCAN"
            repeat {
                iterations += 1
                guard iterations <= 1_000 else { throw MobileRedisMutationError.tooLarge }
                let reply = try await command([scan, key, String(cursor), "COUNT", "100"])
                guard let values = reply.collectionValues, values.count == 2,
                      let next = values[0].stringValue.flatMap(UInt64.init), let members = values[1].collectionValues else { throw RedisWorkspaceError.invalidReply(scan) }
                cursor = next
                let step = type == .set ? 1 : 2
                guard members.count.isMultiple(of: step) else { throw RedisWorkspaceError.invalidReply(scan) }
                for index in stride(from: 0, to: members.count, by: step) {
                    guard let first = members[index].dataValue else { throw RedisWorkspaceError.invalidReply(scan) }
                    let second = step == 2 ? members[index + 1].dataValue : Data()
                    guard let second else { throw RedisWorkspaceError.invalidReply(scan) }
                    if seen.insert(first).inserted { try append(first, second) }
                }
            } while cursor != 0
        }
        var fieldExpirationSupport: Bool? = false
        if type == .hash {
            fieldExpirationSupport = try? await RedisHashFieldExpirationReader.support(client: client)
            if fieldExpirationSupport == true {
                let values = try await RedisHashFieldExpirationReader.read(fields: rows.map(\.originalFirstData), key: .init(databaseIndex: database, name: key, type: type), client: client)
                guard !values.contains(-2) else { throw RedisWorkspaceError.mutationConflict(key) }
                rows = zip(rows, values).map { row, ttl in
                    .init(id: row.id, isNew: false, firstValue: row.firstValue, secondValue: row.secondValue, thirdValue: ttl >= 0 ? String(ttl) : "", originalFirstData: row.originalFirstData, originalSecondData: row.originalSecondData, isBinaryReadOnly: row.isBinaryReadOnly)
                }
            }
        }
        let ttl = try await command(["PTTL", key]).integerValue ?? -2
        if ttl == -2 { return nil }
        guard try await command(["TYPE", key]).stringValue == type.rawValue,
              try await command([countCommand, key]).integerValue == Int64(count),
              type == .string ? string?.data.count == count : rows.count == count else { throw RedisWorkspaceError.mutationConflict(key) }
        let details = RedisKeyDetails(reference: .init(databaseIndex: database, name: key, type: type), ttlMilliseconds: ttl < 0 ? nil : ttl, memoryUsageBytes: nil, encoding: nil, value: .init(columns: [], rows: [], isTruncated: false))
        return .init(details: details, stringData: string, rows: rows, count: count, hashFieldExpirationSupport: fieldExpirationSupport)
    }

    func apply(_ request: RedisOptimisticMutationRequest) async throws {
        let client = try client(database: request.reference.databaseIndex)
        do {
            try await client.connect(); try Task.checkCancellation()
            do { try await client.executeOptimisticMutation(request) }
            catch RedisWorkspaceError.mutationConflict(let key) { throw RedisWorkspaceError.mutationConflict(key) }
            catch { throw MobileRedisMutationError.unverified(error.localizedDescription) }
            await client.close()
        } catch { await client.close(); throw error }
    }
}
