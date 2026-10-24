#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

enum RedisScanCodec {
    static func arguments(cursor: UInt64, pattern: String?, count: Int) -> [String] {
        var args = ["SCAN", String(cursor)]
        if let pattern, !pattern.isEmpty { args += ["MATCH", pattern] }
        return args + ["COUNT", String(max(1, count))]
    }
    static func page(_ reply: RedisReplyValue, databaseIndex: Int) throws -> RedisKeyScanPage {
        guard let parts = reply.collectionValues, parts.count == 2,
              let text = parts[0].stringValue, let cursor = UInt64(text), let keys = parts[1].collectionValues else {
            throw RedisWorkspaceError.invalidReply("SCAN")
        }
        return .init(nextCursor: cursor, keys: keys.compactMap(\.stringValue).map { .init(databaseIndex: databaseIndex, name: $0) })
    }
}
