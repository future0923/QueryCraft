import Foundation
import QueryCraftFeature

actor RedisDriverWorkspaceSession: RedisTransactionalMutationSession,
    RedisCollectionPagingSession,
    RedisBinaryStringSession,
    RedisKeyTypeResolvingSession,
    RedisOptimisticMutationSession,
    WorkspaceSessionCapabilityProviding
{
    let capabilities = WorkspaceSessionCapabilities.redis

    private let configuration: RedisConnectionConfiguration
    var client: RedisClient?
    var hashFieldExpirationSupport: Bool?

    init(configuration: RedisConnectionConfiguration) {
        self.configuration = configuration
    }

    func connect() async throws {
        try await LicenseAccessGate.shared.requireDatabaseAccess()
        if await client?.isConnected() == true { return }
        let newClient = RedisClient(configuration: configuration)
        try await newClient.connect()
        try Task.checkCancellation()
        client = newClient
    }

    func isConnected() async -> Bool {
        await client?.isConnected() == true
    }

    func fetchDatabases() async throws -> [String] {
        try await fetchRedisLogicalDatabases().map(\.name)
    }

    func fetchRedisLogicalDatabases() async throws
        -> [RedisLogicalDatabase]
    {
        let client = try requireClient()
        let clusterInfo = try await client.execute(["INFO", "cluster"])
        try Task.checkCancellation()
        let keyCounts = try? await fetchKeyCounts(client: client)
        if clusterInfo.stringValue?.contains("cluster_enabled:1") == true {
            return [
                RedisLogicalDatabase(
                    index: 0,
                    keyCount: keyCounts.map { $0[0, default: 0] }
                ),
            ]
        }

        let configuredCount = await configuredDatabaseCount(client: client)
        let highestObservedIndex = keyCounts?.keys.max().map { $0 + 1 } ?? 0
        let count = max(configuredCount ?? 16, highestObservedIndex, 1)
        return (0..<count).map { index in
            RedisLogicalDatabase(
                index: index,
                keyCount: keyCounts.map { $0[index, default: 0] }
            )
        }
    }

    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        guard context.schemaName == nil else {
            throw WorkspaceSessionError.queryUnavailable
        }
        guard let index = RedisConnectionConfiguration.databaseIndex(
            from: context.databaseName
        ) else {
            throw RedisWorkspaceError.invalidLogicalDatabase(
                context.databaseName ?? ""
            )
        }
        _ = try await requireClient().execute(
            ["SELECT", String(index)],
            databaseIndex: index
        )
    }

    func scanRedisKeys(
        databaseIndex: Int,
        cursor: UInt64,
        pattern: String?,
        count: Int
    ) async throws -> RedisKeyScanPage {
        var arguments = ["SCAN", String(cursor)]
        if let pattern, !pattern.isEmpty {
            arguments.append(contentsOf: ["MATCH", pattern])
        }
        arguments.append(contentsOf: ["COUNT", String(max(1, count))])
        let reply = try await requireClient().execute(
            arguments,
            databaseIndex: databaseIndex
        )
        try Task.checkCancellation()
        guard let parts = reply.collectionValues,
              parts.count == 2,
              let nextCursorText = parts[0].stringValue,
              let nextCursor = UInt64(nextCursorText),
              let keyValues = parts[1].collectionValues
        else {
            throw invalidReply("SCAN")
        }
        let keys = keyValues.compactMap(\.stringValue).map {
            RedisKeyReference(databaseIndex: databaseIndex, name: $0)
        }
        return RedisKeyScanPage(nextCursor: nextCursor, keys: keys)
    }

    func fetchRedisKey(
        _ reference: RedisKeyReference,
        maximumElements: Int
    ) async throws -> RedisKeyDetails {
        let client = try requireClient()
        let typeReply = try await client.execute(
            ["TYPE", reference.name],
            databaseIndex: reference.databaseIndex
        )
        try Task.checkCancellation()
        let type = RedisKeyType(rawValue: typeReply.stringValue ?? "")
            ?? .unknown
        let resolvedReference = RedisKeyReference(
            databaseIndex: reference.databaseIndex,
            name: reference.name,
            type: type
        )
        let ttl = try await optionalInteger(
            ["PTTL", reference.name],
            client: client,
            databaseIndex: reference.databaseIndex
        )
        let memory = try await optionalInteger(
            ["MEMORY", "USAGE", reference.name],
            client: client,
            databaseIndex: reference.databaseIndex
        )
        let encoding = try await optionalString(
            ["OBJECT", "ENCODING", reference.name],
            client: client,
            databaseIndex: reference.databaseIndex
        )
        let value = try await fetchValue(
            for: resolvedReference,
            maximumElements: max(1, maximumElements),
            client: client
        )
        return RedisKeyDetails(
            reference: resolvedReference,
            ttlMilliseconds: ttl.flatMap { $0 >= 0 ? $0 : nil },
            memoryUsageBytes: memory.flatMap { $0 >= 0 ? $0 : nil },
            encoding: encoding,
            value: value
        )
    }

    func executeRedisCommand(
        _ invocation: RedisCommandInvocation,
        databaseIndex: Int
    ) async throws -> RedisCommandResult {
        guard !invocation.arguments.isEmpty else {
            throw RedisWorkspaceError.invalidCommand
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let reply = try await requireClient().execute(
            invocation.arguments,
            databaseIndex: databaseIndex
        )
        let duration = startedAt.duration(to: clock.now).components
        let elapsed = Double(duration.seconds)
            + Double(duration.attoseconds) / 1_000_000_000_000_000_000
        return RedisCommandResult(
            invocation: invocation,
            reply: reply,
            elapsedSeconds: elapsed
        )
    }

    func executeRedisTransaction(
        _ invocations: [RedisCommandInvocation],
        databaseIndex: Int
    ) async throws {
        try await requireClient().executeTransaction(
            invocations.map(\.arguments),
            databaseIndex: databaseIndex
        )
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        []
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        throw WorkspaceSessionError.queryUnavailable
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        throw WorkspaceSessionError.queryUnavailable
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        throw WorkspaceSessionError.queryUnavailable
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func close() async {
        let activeClient = client
        client = nil
        await activeClient?.close()
    }

    private func fetchKeyCounts(
        client: RedisClient
    ) async throws -> [Int: Int] {
        let reply = try await client.execute(["INFO", "keyspace"])
        guard let info = reply.stringValue else { return [:] }
        return RedisKeyspaceInfoParser.parse(info)
    }

    private func configuredDatabaseCount(
        client: RedisClient
    ) async -> Int? {
        guard let reply = try? await client.execute(
            ["CONFIG", "GET", "databases"]
        ) else { return nil }
        switch reply {
        case .array(let values):
            return values.last?.stringValue.flatMap(Int.init)
        case .map(let entries):
            return entries.first(where: {
                $0.key.stringValue == "databases"
            })?.value.stringValue.flatMap(Int.init)
        default:
            return nil
        }
    }

    private func fetchValue(
        for reference: RedisKeyReference,
        maximumElements: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        if maximumElements == 0 {
            let columns: [String] = switch reference.type {
            case .string: ["value"]
            case .list: ["index", "value"]
            case .hash: ["field", "value"]
            case .set: ["value"]
            case .sortedSet: ["value", "score"]
            case .stream: ["entryID", "fields"]
            case .module, .unknown, .none: ["value"]
            }
            return RedisKeyValueSnapshot(
                columns: columns,
                rows: [],
                isTruncated: reference.type != .none
            )
        }
        switch reference.type {
        case .string:
            return try await fetchString(
                reference,
                maximumBytes: 65_536,
                client: client
            )
        case .list:
            return try await fetchList(
                reference,
                maximumElements: maximumElements,
                client: client
            )
        case .set:
            return try await fetchSet(
                reference,
                maximumElements: maximumElements,
                client: client
            )
        case .sortedSet:
            return try await fetchSortedSet(
                reference,
                maximumElements: maximumElements,
                client: client
            )
        case .hash:
            return try await fetchHash(
                reference,
                maximumElements: maximumElements,
                client: client
            )
        case .stream:
            return try await fetchStream(
                reference,
                maximumElements: maximumElements,
                client: client
            )
        case .none:
            return RedisKeyValueSnapshot(columns: ["value"], rows: [])
        case .module, .unknown:
            throw RedisWorkspaceError.unsupportedKeyType(
                reference.type.rawValue
            )
        }
    }

    private func fetchString(
        _ reference: RedisKeyReference,
        maximumBytes: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        let length = try await client.execute(
            ["STRLEN", reference.name],
            databaseIndex: reference.databaseIndex
        ).integerValue ?? 0
        let reply = try await client.execute(
            ["GETRANGE", reference.name, "0", String(maximumBytes - 1)],
            databaseIndex: reference.databaseIndex
        )
        guard let value = reply.stringValue else { throw invalidReply("GETRANGE") }
        return RedisKeyValueSnapshot(
            columns: ["value"],
            rows: [[value]],
            isTruncated: length > maximumBytes
        )
    }

    private func fetchList(
        _ reference: RedisKeyReference,
        maximumElements: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        let count = try await client.execute(
            ["LLEN", reference.name],
            databaseIndex: reference.databaseIndex
        ).integerValue ?? 0
        let reply = try await client.execute(
            ["LRANGE", reference.name, "0", String(maximumElements - 1)],
            databaseIndex: reference.databaseIndex
        )
        let rows = (reply.collectionValues ?? []).enumerated().map {
            [String($0.offset), $0.element.stringValue ?? ""]
        }
        return RedisKeyValueSnapshot(
            columns: ["index", "value"],
            rows: rows,
            isTruncated: count > rows.count
        )
    }

    private func fetchSet(
        _ reference: RedisKeyReference,
        maximumElements: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        let reply = try await client.execute(
            ["SSCAN", reference.name, "0", "COUNT", String(maximumElements)],
            databaseIndex: reference.databaseIndex
        )
        let page = try scanCollection(reply, command: "SSCAN")
        return RedisKeyValueSnapshot(
            columns: ["value"],
            rows: page.values.map { [$0.stringValue ?? ""] },
            isTruncated: page.nextCursor != 0
        )
    }

    private func fetchHash(
        _ reference: RedisKeyReference,
        maximumElements: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        let reply = try await client.execute(
            ["HSCAN", reference.name, "0", "COUNT", String(maximumElements)],
            databaseIndex: reference.databaseIndex
        )
        let page = try scanCollection(reply, command: "HSCAN")
        let flat = page.values
        let rows = stride(from: 0, to: max(0, flat.count - 1), by: 2).map {
            [flat[$0].stringValue ?? "", flat[$0 + 1].stringValue ?? ""]
        }
        return RedisKeyValueSnapshot(
            columns: ["field", "value"],
            rows: rows,
            isTruncated: page.nextCursor != 0
        )
    }

    private func fetchSortedSet(
        _ reference: RedisKeyReference,
        maximumElements: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        let count = try await client.execute(
            ["ZCARD", reference.name],
            databaseIndex: reference.databaseIndex
        ).integerValue ?? 0
        let reply = try await client.execute(
            ["ZRANGE", reference.name, "0", String(maximumElements - 1), "WITHSCORES"],
            databaseIndex: reference.databaseIndex
        )
        let values = reply.collectionValues ?? []
        let rows: [[String]]
        if values.allSatisfy({ $0.collectionValues?.count == 2 }) {
            rows = values.compactMap { value in
                guard let pair = value.collectionValues, pair.count == 2 else {
                    return nil
                }
                return [pair[0].stringValue ?? "", pair[1].stringValue ?? ""]
            }
        } else {
            rows = stride(from: 0, to: max(0, values.count - 1), by: 2).map {
                [values[$0].stringValue ?? "", values[$0 + 1].stringValue ?? ""]
            }
        }
        return RedisKeyValueSnapshot(
            columns: ["value", "score"],
            rows: rows,
            isTruncated: count > rows.count
        )
    }

    private func fetchStream(
        _ reference: RedisKeyReference,
        maximumElements: Int,
        client: RedisClient
    ) async throws -> RedisKeyValueSnapshot {
        let count = try await client.execute(
            ["XLEN", reference.name],
            databaseIndex: reference.databaseIndex
        ).integerValue ?? 0
        let reply = try await client.execute(
            ["XRANGE", reference.name, "-", "+", "COUNT", String(maximumElements)],
            databaseIndex: reference.databaseIndex
        )
        let rows = (reply.collectionValues ?? []).compactMap { entry -> [String]? in
            guard let parts = entry.collectionValues, parts.count == 2 else {
                return nil
            }
            let fieldValues = parts[1].collectionValues ?? []
            let fields = stride(
                from: 0,
                to: max(0, fieldValues.count - 1),
                by: 2
            ).map {
                "\(fieldValues[$0].stringValue ?? "")=\(fieldValues[$0 + 1].stringValue ?? "")"
            }.joined(separator: ", ")
            return [parts[0].stringValue ?? "", fields]
        }
        return RedisKeyValueSnapshot(
            columns: ["entryID", "fields"],
            rows: rows,
            isTruncated: count > rows.count
        )
    }

    private func scanCollection(
        _ reply: RedisReplyValue,
        command: String
    ) throws -> (nextCursor: UInt64, values: [RedisReplyValue]) {
        guard let parts = reply.collectionValues,
              parts.count == 2,
              let cursorText = parts[0].stringValue,
              let cursor = UInt64(cursorText),
              let values = parts[1].collectionValues
        else {
            throw invalidReply(command)
        }
        return (cursor, values)
    }

    private func optionalInteger(
        _ arguments: [String],
        client: RedisClient,
        databaseIndex: Int
    ) async throws -> Int64? {
        let reply = try await client.execute(
            arguments,
            databaseIndex: databaseIndex
        )
        if case .error = reply { return nil }
        return reply.integerValue
    }

    private func optionalString(
        _ arguments: [String],
        client: RedisClient,
        databaseIndex: Int
    ) async throws -> String? {
        let reply = try await client.execute(
            arguments,
            databaseIndex: databaseIndex
        )
        if case .error = reply { return nil }
        return reply.stringValue
    }

    func requireClient() throws -> RedisClient {
        guard let client else { throw WorkspaceSessionError.notConnected }
        return client
    }

    private func invalidReply(_ command: String) -> RedisClientError {
        RedisClientError(message: "Redis returned an invalid \(command) reply.")
    }
}
