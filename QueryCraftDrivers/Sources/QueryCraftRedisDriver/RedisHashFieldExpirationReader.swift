#if os(iOS)
import QueryCraftMobileCore
#else
import QueryCraftFeature
#endif
import Foundation

// Shared by desktop paged reads and mobile editing snapshots.
enum RedisHashFieldExpirationReader {
    static func support(client: RedisClient) async throws -> Bool {
        let reply = try await client.execute(["COMMAND", "INFO", "HPTTL"])
        if case .error(let message) = reply { throw RedisClientError(message: message) }
        guard let values = reply.collectionValues, values.count == 1 else { throw RedisWorkspaceError.invalidReply("COMMAND INFO HPTTL") }
        return values[0] != .null
    }
    static func read(fields: [RedisBinaryValue], key: RedisKeyReference, client: RedisClient) async throws -> [Int64] {
        guard !fields.isEmpty else { return [] }
        let arguments = ["HPTTL", key.name, "FIELDS", String(fields.count)].map(RedisBinaryValue.init(utf8:)) + fields
        let reply = try await client.executeRaw(arguments, databaseIndex: key.databaseIndex)
        if case .error(let message) = reply { throw RedisClientError(message: message) }
        guard let values = reply.collectionValues, values.count == fields.count else { throw RedisWorkspaceError.invalidReply("HPTTL") }
        return try values.map {
            guard let value = $0.integerValue, value >= -2 else { throw RedisWorkspaceError.invalidReply("HPTTL") }
            return value
        }
    }
}
