import Foundation
#if os(iOS)
import QueryCraftMobileCore
#else
import QueryCraftFeature
#endif

struct RedisStreamPage: Sendable {
    let totalCount: Int
    let rows: [[String]]
    let lastID: String?
    let hasMore: Bool
}

enum RedisStreamReader {
    static func read(client: RedisClient, reference: RedisKeyReference, afterID: String? = nil, limit: Int) async throws -> RedisStreamPage {
        let countReply = try await client.execute(["XLEN", reference.name], databaseIndex: reference.databaseIndex)
        if case .error(let message) = countReply { throw RedisClientError(message: message) }
        guard let count = countReply.integerValue, let total = Int(exactly: count), total >= 0 else { throw RedisWorkspaceError.invalidReply("XLEN") }
        let bounded = max(1, min(limit, 10_000))
        let reply = try await client.executeRaw(["XRANGE", reference.name, afterID.map { "(" + $0 } ?? "-", "+", "COUNT", String(bounded + 1)].map(RedisBinaryValue.init(utf8:)), databaseIndex: reference.databaseIndex)
        if case .error(let message) = reply { throw RedisClientError(message: message) }
        guard let values = reply.collectionValues else { throw RedisWorkspaceError.invalidReply("XRANGE") }
        func text(_ value: RedisRawReplyValue) throws -> String {
            guard let data = value.dataValue else { throw RedisWorkspaceError.invalidReply("XRANGE field") }
            return String(data: data, encoding: .utf8) ?? "HEX: " + data.map { String(format: "%02x", $0) }.joined()
        }
        var rows: [[String]] = []
        for entry in values.prefix(bounded) {
            try Task.checkCancellation()
            guard let parts = entry.collectionValues, parts.count == 2, let id = parts[0].stringValue,
                  let fields = parts[1].collectionValues, fields.count.isMultiple(of: 2) else { throw RedisWorkspaceError.invalidReply("XRANGE entry") }
            let formatted = try stride(from: 0, to: fields.count, by: 2).map { try text(fields[$0]) + "=" + text(fields[$0 + 1]) }.joined(separator: ", ")
            rows.append([id, formatted])
        }
        return .init(totalCount: total, rows: rows, lastID: rows.last?.first, hasMore: values.count > bounded)
    }
}
