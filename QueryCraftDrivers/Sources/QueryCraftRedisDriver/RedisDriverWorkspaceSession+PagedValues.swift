import Foundation
import QueryCraftFeature

extension RedisDriverWorkspaceSession {
    func fetchRedisStringChunk(
        _ reference: RedisKeyReference,
        offset: Int,
        maximumBytes: Int
    ) async throws -> RedisStringChunk {
        let client = try requireClient()
        let total = Int(try await client.execute(
            ["STRLEN", reference.name],
            databaseIndex: reference.databaseIndex
        ).integerValue ?? 0)
        try Task.checkCancellation()
        let start = max(0, offset)
        let count = max(1, maximumBytes)
        let reply = try await client.executeRaw(
            binaryArguments([
                "GETRANGE",
                reference.name,
                String(start),
                String(start + count - 1),
            ]),
            databaseIndex: reference.databaseIndex
        )
        guard let data = reply.dataValue else {
            throw RedisWorkspaceError.invalidReply("GETRANGE")
        }
        return RedisStringChunk(
            value: RedisBinaryValue(data: data),
            offset: start,
            totalByteCount: total
        )
    }

    func resolveRedisKeyTypes(
        _ references: [RedisKeyReference]
    ) async throws -> [RedisKeyReference] {
        let client = try requireClient()
        var resolved = references
        let grouped = Dictionary(
            grouping: references.enumerated(),
            by: { $0.element.databaseIndex }
        )
        for databaseIndex in grouped.keys.sorted() {
            try Task.checkCancellation()
            guard let indexedReferences = grouped[databaseIndex] else {
                continue
            }
            let replies = try await client.executePipeline(
                indexedReferences.map { ["TYPE", $0.element.name] },
                databaseIndex: databaseIndex
            )
            guard replies.count == indexedReferences.count else {
                throw RedisWorkspaceError.invalidReply("TYPE pipeline")
            }
            for (indexedReference, reply) in zip(indexedReferences, replies) {
                let reference = indexedReference.element
                resolved[indexedReference.offset] = RedisKeyReference(
                    databaseIndex: databaseIndex,
                    name: reference.name,
                    type: RedisKeyType(rawValue: reply.stringValue ?? "")
                        ?? .unknown
                )
            }
        }
        return resolved
    }

    func fetchRedisCollectionPage(
        _ query: RedisCollectionQuery
    ) async throws -> RedisCollectionPage {
        let client = try requireClient()
        let limit = min(max(1, query.limit), 500_000)
        switch query.reference.type {
        case .list:
            return try await fetchListPage(query, limit: limit, client: client)
        case .hash:
            return try await fetchHashPage(query, limit: limit, client: client)
        case .set:
            return try await fetchSetPage(query, limit: limit, client: client)
        case .sortedSet:
            return try await fetchSortedSetPage(query, limit: limit, client: client)
        case .string, .stream, .module, .unknown, .none:
            throw RedisWorkspaceError.unsupportedKeyType(
                query.reference.type.rawValue
            )
        }
    }

    private func fetchListPage(
        _ query: RedisCollectionQuery,
        limit: Int,
        client: RedisClient
    ) async throws -> RedisCollectionPage {
        let total = try await cardinality(
            "LLEN",
            reference: query.reference,
            client: client
        )
        var state = OffsetContinuation(query.continuation)
        var entries: [RedisCollectionEntry] = []
        let batchSize = query.search == nil ? limit : 2_000
        while entries.count < limit, state.offset < total {
            try Task.checkCancellation()
            let end = min(total - 1, state.offset + batchSize - 1)
            let reply = try await client.executeRaw(
                binaryArguments([
                    "LRANGE", query.reference.name,
                    String(state.offset), String(end),
                ]),
                databaseIndex: query.reference.databaseIndex
            )
            guard let values = reply.collectionValues else {
                throw RedisWorkspaceError.invalidReply("LRANGE")
            }
            let batchOffset = state.offset
            for (relativeIndex, value) in values.enumerated() {
                let index = batchOffset + relativeIndex
                state.offset = index + 1
                state.scanned = state.offset
                guard let data = value.dataValue else { continue }
                if matchesList(data, search: query.search) {
                    entries.append(
                        .list(
                            index: index,
                            value: RedisBinaryValue(data: data)
                        )
                    )
                    state.matched += 1
                }
                if entries.count >= limit { break }
            }
            if values.isEmpty {
                state.offset = end + 1
                state.scanned = state.offset
            }
        }
        let complete = state.offset >= total
        return RedisCollectionPage(
            entries: entries,
            totalCount: total,
            scannedCount: state.scanned,
            matchingCount: complete ? state.matched : nil,
            continuation: complete ? nil : state.continuation,
            reachedRetainedLimit: entries.count >= 500_000
        )
    }

    private func fetchSortedSetPage(
        _ query: RedisCollectionQuery,
        limit: Int,
        client: RedisClient
    ) async throws -> RedisCollectionPage {
        let total = try await cardinality(
            "ZCARD",
            reference: query.reference,
            client: client
        )
        var state = OffsetContinuation(query.continuation)
        var entries: [RedisCollectionEntry] = []
        let batchSize = query.search == nil ? limit : 2_000
        while entries.count < limit, state.offset < total {
            try Task.checkCancellation()
            let end = min(total - 1, state.offset + batchSize - 1)
            var arguments = ["ZRANGE", query.reference.name]
            if query.sortOrder == .descending {
                arguments.append(contentsOf: [
                    String(state.offset), String(end), "REV", "WITHSCORES",
                ])
            } else {
                arguments.append(contentsOf: [
                    String(state.offset), String(end), "WITHSCORES",
                ])
            }
            let reply = try await client.executeRaw(
                binaryArguments(arguments),
                databaseIndex: query.reference.databaseIndex
            )
            let pairs = try sortedSetPairs(reply)
            let batchOffset = state.offset
            for (relativeIndex, pair) in pairs.enumerated() {
                state.offset = batchOffset + relativeIndex + 1
                state.scanned = state.offset
                if matchesSortedSet(
                    member: pair.member,
                    score: pair.score,
                    search: query.search
                ) {
                    entries.append(
                        .sortedSet(
                            member: RedisBinaryValue(data: pair.member),
                            score: pair.score
                        )
                    )
                    state.matched += 1
                }
                if entries.count >= limit { break }
            }
            if pairs.isEmpty {
                state.offset = end + 1
                state.scanned = state.offset
            }
        }
        let complete = state.offset >= total
        return RedisCollectionPage(
            entries: entries,
            totalCount: total,
            scannedCount: state.scanned,
            matchingCount: complete ? state.matched : nil,
            continuation: complete ? nil : state.continuation,
            reachedRetainedLimit: entries.count >= 500_000
        )
    }

    private func fetchHashPage(
        _ query: RedisCollectionQuery,
        limit: Int,
        client: RedisClient
    ) async throws -> RedisCollectionPage {
        let total = try await cardinality(
            "HLEN",
            reference: query.reference,
            client: client
        )
        var state = ScanContinuation(query.continuation)
        var pairs: [(field: Data, value: Data)] = []
        repeat {
            try Task.checkCancellation()
            var arguments = [
                "HSCAN", query.reference.name, String(state.cursor),
            ]
            if let pattern = serverPattern(
                for: query.search,
                supportedField: .field
            ) {
                arguments.append(contentsOf: ["MATCH", pattern])
            }
            arguments.append(contentsOf: [
                "COUNT", String(query.search == nil ? limit : 2_000),
            ])
            let reply = try await client.executeRaw(
                binaryArguments(arguments),
                databaseIndex: query.reference.databaseIndex
            )
            let page = try scanPage(reply, command: "HSCAN")
            state.cursor = page.cursor
            state.scanned = min(total, state.scanned + page.values.count / 2)
            let values = page.values
            for index in stride(from: 0, to: values.count - 1, by: 2) {
                guard let field = values[index].dataValue,
                      let value = values[index + 1].dataValue,
                      matchesHash(field: field, value: value, search: query.search)
                else { continue }
                pairs.append((field, value))
                state.matched += 1
            }
        } while pairs.count < limit && state.cursor != 0

        let supportsTTL = await supportsHashFieldExpiration(client: client)
        let ttlValues = supportsTTL
            ? await hashFieldTTLs(
                pairs.map(\.field),
                reference: query.reference,
                client: client
            )
            : []
        let entries = pairs.enumerated().map { index, pair in
            RedisCollectionEntry.hash(
                field: RedisBinaryValue(data: pair.field),
                value: RedisBinaryValue(data: pair.value),
                ttlMilliseconds: ttlValues.indices.contains(index)
                    ? ttlValues[index]
                    : nil
            )
        }
        let complete = state.cursor == 0
        return RedisCollectionPage(
            entries: entries,
            totalCount: total,
            scannedCount: complete ? total : state.scanned,
            matchingCount: complete ? state.matched : nil,
            continuation: complete ? nil : state.continuation,
            supportsHashFieldExpiration: supportsTTL,
            reachedRetainedLimit: entries.count >= 500_000
        )
    }

    private func fetchSetPage(
        _ query: RedisCollectionQuery,
        limit: Int,
        client: RedisClient
    ) async throws -> RedisCollectionPage {
        let total = try await cardinality(
            "SCARD",
            reference: query.reference,
            client: client
        )
        var state = ScanContinuation(query.continuation)
        var entries: [RedisCollectionEntry] = []
        repeat {
            try Task.checkCancellation()
            var arguments = [
                "SSCAN", query.reference.name, String(state.cursor),
            ]
            if let pattern = serverPattern(
                for: query.search,
                supportedField: .member
            ) {
                arguments.append(contentsOf: ["MATCH", pattern])
            }
            arguments.append(contentsOf: [
                "COUNT", String(query.search == nil ? limit : 2_000),
            ])
            let reply = try await client.executeRaw(
                binaryArguments(arguments),
                databaseIndex: query.reference.databaseIndex
            )
            let page = try scanPage(reply, command: "SSCAN")
            state.cursor = page.cursor
            state.scanned = min(total, state.scanned + page.values.count)
            for value in page.values {
                guard let data = value.dataValue,
                      matchesSet(data, search: query.search)
                else { continue }
                entries.append(.set(member: RedisBinaryValue(data: data)))
                state.matched += 1
            }
        } while entries.count < limit && state.cursor != 0
        let complete = state.cursor == 0
        return RedisCollectionPage(
            entries: entries,
            totalCount: total,
            scannedCount: complete ? total : state.scanned,
            matchingCount: complete ? state.matched : nil,
            continuation: complete ? nil : state.continuation,
            reachedRetainedLimit: entries.count >= 500_000
        )
    }

    private func cardinality(
        _ command: String,
        reference: RedisKeyReference,
        client: RedisClient
    ) async throws -> Int {
        Int(try await client.execute(
            [command, reference.name],
            databaseIndex: reference.databaseIndex
        ).integerValue ?? 0)
    }

    private func supportsHashFieldExpiration(
        client: RedisClient
    ) async -> Bool {
        if let hashFieldExpirationSupport {
            return hashFieldExpirationSupport
        }
        let supported: Bool
        do {
            let reply = try await client.execute(["COMMAND", "INFO", "HPTTL"])
            supported = reply.collectionValues?.first.map {
                if case .null = $0 { return false }
                return true
            } ?? false
        } catch {
            supported = false
        }
        hashFieldExpirationSupport = supported
        return supported
    }

    private func hashFieldTTLs(
        _ fields: [Data],
        reference: RedisKeyReference,
        client: RedisClient
    ) async -> [Int64?] {
        guard !fields.isEmpty else { return [] }
        var arguments = binaryArguments([
            "HPTTL", reference.name, "FIELDS", String(fields.count),
        ])
        arguments.append(contentsOf: fields.map(RedisBinaryValue.init(data:)))
        guard let reply = try? await client.executeRaw(
            arguments,
            databaseIndex: reference.databaseIndex
        ), let values = reply.collectionValues else {
            return Array(repeating: nil, count: fields.count)
        }
        return values.map { value in
            guard let milliseconds = value.integerValue,
                  milliseconds >= 0
            else { return nil }
            return milliseconds
        }
    }

    private func scanPage(
        _ reply: RedisRawReplyValue,
        command: String
    ) throws -> (cursor: UInt64, values: [RedisRawReplyValue]) {
        guard let parts = reply.collectionValues,
              parts.count == 2,
              let cursorText = parts[0].stringValue,
              let cursor = UInt64(cursorText),
              let values = parts[1].collectionValues
        else {
            throw RedisWorkspaceError.invalidReply(command)
        }
        return (cursor, values)
    }

    private func sortedSetPairs(
        _ reply: RedisRawReplyValue
    ) throws -> [(member: Data, score: String)] {
        guard let values = reply.collectionValues else {
            throw RedisWorkspaceError.invalidReply("ZRANGE")
        }
        if values.allSatisfy({ $0.collectionValues?.count == 2 }) {
            return values.compactMap { value in
                guard let pair = value.collectionValues,
                      pair.count == 2,
                      let member = pair[0].dataValue,
                      let score = pair[1].stringValue
                else { return nil }
                return (member, score)
            }
        }
        return stride(from: 0, to: values.count - 1, by: 2).compactMap {
            guard let member = values[$0].dataValue,
                  let score = values[$0 + 1].stringValue
            else { return nil }
            return (member, score)
        }
    }

    private func matchesList(
        _ value: Data,
        search: RedisCollectionSearch?
    ) -> Bool {
        guard let search else { return true }
        return matches(value, search: search)
    }

    private func matchesSet(
        _ member: Data,
        search: RedisCollectionSearch?
    ) -> Bool {
        guard let search else { return true }
        return matches(member, search: search)
    }

    private func matchesHash(
        field: Data,
        value: Data,
        search: RedisCollectionSearch?
    ) -> Bool {
        guard let search else { return true }
        switch search.field {
        case .field: return matches(field, search: search)
        case .value: return matches(value, search: search)
        case .all:
            return matches(field, search: search)
                || matches(value, search: search)
        case .member, .score: return false
        }
    }

    private func matchesSortedSet(
        member: Data,
        score: String,
        search: RedisCollectionSearch?
    ) -> Bool {
        guard let search else { return true }
        switch search.field {
        case .member: return matches(member, search: search)
        case .score: return matches(Data(score.utf8), search: search)
        case .all:
            return matches(member, search: search)
                || matches(Data(score.utf8), search: search)
        case .field, .value: return false
        }
    }

    private func matches(
        _ candidate: Data,
        search: RedisCollectionSearch
    ) -> Bool {
        let query = Data(search.text.utf8)
        if search.isCaseSensitive {
            switch search.mode {
            case .contains: return candidate.range(of: query) != nil
            case .prefix: return candidate.starts(with: query)
            case .exact: return candidate == query
            }
        }
        guard let candidateText = String(data: candidate, encoding: .utf8) else {
            return false
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        switch search.mode {
        case .contains:
            return candidateText.range(of: search.text, options: options) != nil
        case .prefix:
            return candidateText.range(
                of: search.text,
                options: options.union(.anchored)
            ) != nil
        case .exact:
            return candidateText.compare(search.text, options: options) == .orderedSame
        }
    }

    private func serverPattern(
        for search: RedisCollectionSearch?,
        supportedField: RedisCollectionSearchField
    ) -> String? {
        guard let search,
              search.isCaseSensitive,
              search.field == supportedField
        else { return nil }
        let escaped = search.text.reduce(into: "") { result, character in
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        switch search.mode {
        case .contains: return "*\(escaped)*"
        case .prefix: return "\(escaped)*"
        case .exact: return escaped
        }
    }

    private func binaryArguments(_ values: [String]) -> [RedisBinaryValue] {
        values.map(RedisBinaryValue.init(utf8:))
    }
}

struct OffsetContinuation {
    var offset: Int
    var scanned: Int
    var matched: Int

    init(_ continuation: RedisCollectionContinuation?) {
        let components = continuation?.rawValue.split(separator: ":") ?? []
        offset = components.count > 0 ? Int(components[0]) ?? 0 : 0
        scanned = components.count > 1 ? Int(components[1]) ?? offset : offset
        matched = components.count > 2 ? Int(components[2]) ?? 0 : 0
    }

    var continuation: RedisCollectionContinuation {
        RedisCollectionContinuation(
            rawValue: "\(offset):\(scanned):\(matched)"
        )
    }
}

struct ScanContinuation {
    var cursor: UInt64
    var scanned: Int
    var matched: Int

    init(_ continuation: RedisCollectionContinuation?) {
        let components = continuation?.rawValue.split(separator: ":") ?? []
        cursor = components.count > 0 ? UInt64(components[0]) ?? 0 : 0
        scanned = components.count > 1 ? Int(components[1]) ?? 0 : 0
        matched = components.count > 2 ? Int(components[2]) ?? 0 : 0
    }

    var continuation: RedisCollectionContinuation {
        RedisCollectionContinuation(
            rawValue: "\(cursor):\(scanned):\(matched)"
        )
    }
}
