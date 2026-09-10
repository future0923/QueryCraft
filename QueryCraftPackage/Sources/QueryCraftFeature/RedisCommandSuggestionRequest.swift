import Foundation

enum RedisCommandSuggestionDomain: Hashable, Sendable {
    case hashField
    case setMember
    case sortedSetMember

    var scanCommand: String {
        switch self {
        case .hashField: "HSCAN"
        case .setMember: "SSCAN"
        case .sortedSetMember: "ZSCAN"
        }
    }

    @MainActor
    var suggestionDetail: String {
        switch self {
        case .hashField:
            AppCopy.current.text("Hash 字段", "Hash field")
        case .setMember:
            AppCopy.current.text("Set 成员", "Set member")
        case .sortedSetMember:
            AppCopy.current.text("ZSet 成员", "ZSet member")
        }
    }
}

struct RedisCommandSuggestionRequest: Hashable, Sendable {
    let databaseIndex: Int
    let key: String
    let domain: RedisCommandSuggestionDomain

    var invocation: RedisCommandInvocation {
        let arguments = [domain.scanCommand, key, "0", "COUNT", "100"]
        return RedisCommandInvocation(
            source: arguments.joined(separator: " "),
            arguments: arguments
        )
    }

    func candidates(from reply: RedisReplyValue) throws -> [String] {
        guard case let .array(parts) = reply,
              parts.count == 2,
              parts[0].redisSuggestionScalar != nil,
              let values = parts[1].redisSuggestionCollection
        else {
            throw RedisWorkspaceError.invalidReply(domain.scanCommand)
        }

        let step = domain == .setMember ? 1 : 2
        var seen = Set<String>()
        return stride(from: 0, to: values.count, by: step)
            .compactMap { values[$0].redisSuggestionScalar }
            .filter { seen.insert($0).inserted }
    }
}

extension RedisCommandLineSnapshot {
    func suggestionRequest(
        databaseIndex: Int
    ) -> RedisCommandSuggestionRequest? {
        guard let entry,
              let argumentIndex = activeArgumentIndex,
              let argument = entry.argument(at: argumentIndex),
              tokenization.arguments.count > 1
        else { return nil }

        let domain: RedisCommandSuggestionDomain?
        switch entry.name {
        case "HGET", "HSET", "HDEL", "HEXISTS":
            domain = argument.kind == .field ? .hashField : nil
        case "SADD", "SREM", "SISMEMBER":
            domain = argument.kind == .value && argument.name == "member"
                ? .setMember
                : nil
        case "ZADD", "ZREM", "ZSCORE":
            domain = argument.kind == .value && argument.name == "member"
                ? .sortedSetMember
                : nil
        default:
            domain = nil
        }
        guard let domain else { return nil }
        return RedisCommandSuggestionRequest(
            databaseIndex: databaseIndex,
            key: tokenization.arguments[1],
            domain: domain
        )
    }
}

private extension RedisReplyValue {
    var redisSuggestionScalar: String? {
        switch self {
        case let .simpleString(value), let .bulkString(value): value
        case let .integer(value): String(value)
        case let .double(value): String(value)
        case let .boolean(value): value ? "1" : "0"
        case .array, .map, .set, .null, .error: nil
        }
    }

    var redisSuggestionCollection: [RedisReplyValue]? {
        switch self {
        case let .array(values), let .set(values): values
        case .simpleString, .bulkString, .integer, .double, .boolean,
             .map, .null, .error:
            nil
        }
    }
}
