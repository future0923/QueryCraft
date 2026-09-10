import Foundation

struct RedisCommandCatalogEntry: Equatable, Identifiable, Sendable {
    let name: String
    let syntax: String
    let summaryZH: String
    let summaryEN: String
    let isReadOnly: Bool
    let arguments: [RedisCommandArgument]
    let repeatingArgumentStartIndex: Int?
    let compatibleKeyTypes: [RedisKeyType]?

    init(
        name: String,
        syntax: String,
        summaryZH: String,
        summaryEN: String,
        isReadOnly: Bool,
        arguments: [RedisCommandArgument] = [],
        repeatingArgumentStartIndex: Int? = nil,
        compatibleKeyTypes: [RedisKeyType]? = nil
    ) {
        self.name = name
        self.syntax = syntax
        self.summaryZH = summaryZH
        self.summaryEN = summaryEN
        self.isReadOnly = isReadOnly
        self.arguments = arguments
        self.repeatingArgumentStartIndex = repeatingArgumentStartIndex
        self.compatibleKeyTypes = compatibleKeyTypes
    }

    var id: String { name }

    @MainActor
    var summary: String { AppCopy.current.text(summaryZH, summaryEN) }

    func argument(at index: Int) -> RedisCommandArgument? {
        guard index >= 0 else { return nil }
        if index < arguments.count { return arguments[index] }
        guard let start = repeatingArgumentStartIndex,
              start >= 0,
              start < arguments.count
        else { return nil }
        let repeatingCount = arguments.count - start
        return arguments[start + ((index - start) % repeatingCount)]
    }
}

enum RedisCommandCatalog {
    static let entries: [RedisCommandCatalogEntry] = [
        .init(name: "GET", syntax: "GET key", summaryZH: "读取字符串值", summaryEN: "Read a string value", isReadOnly: true, arguments: [.key()], compatibleKeyTypes: [.string]),
        .init(name: "SET", syntax: "SET key value [EX seconds]", summaryZH: "设置字符串值", summaryEN: "Set a string value", isReadOnly: false, arguments: [.key(), .value(), .keyword("option", values: ["EX"]), .integer("seconds", optional: true)], compatibleKeyTypes: [.string]),
        .init(name: "DEL", syntax: "DEL key [key ...]", summaryZH: "删除一个或多个 Key", summaryEN: "Delete one or more keys", isReadOnly: false, arguments: [.key()], repeatingArgumentStartIndex: 0),
        .init(name: "EXISTS", syntax: "EXISTS key [key ...]", summaryZH: "检查 Key 是否存在", summaryEN: "Check whether keys exist", isReadOnly: true, arguments: [.key()], repeatingArgumentStartIndex: 0),
        .init(name: "TYPE", syntax: "TYPE key", summaryZH: "读取 Key 类型", summaryEN: "Read a key type", isReadOnly: true, arguments: [.key()]),
        .init(name: "TTL", syntax: "TTL key", summaryZH: "读取剩余秒数", summaryEN: "Read remaining lifetime in seconds", isReadOnly: true, arguments: [.key()]),
        .init(name: "PTTL", syntax: "PTTL key", summaryZH: "读取剩余毫秒数", summaryEN: "Read remaining lifetime in milliseconds", isReadOnly: true, arguments: [.key()]),
        .init(name: "EXPIRE", syntax: "EXPIRE key seconds", summaryZH: "设置过期时间", summaryEN: "Set a key expiration", isReadOnly: false, arguments: [.key(), .integer("seconds")]),
        .init(name: "SCAN", syntax: "SCAN cursor [MATCH pattern] [COUNT count]", summaryZH: "增量扫描 Key", summaryEN: "Incrementally scan keys", isReadOnly: true, arguments: [.cursor(), .keyword("option", values: ["MATCH", "COUNT"]), .other("value", descriptionZH: "MATCH 模式或 COUNT 数量", descriptionEN: "MATCH pattern or COUNT value", optional: true)], repeatingArgumentStartIndex: 1),
        .init(name: "DBSIZE", syntax: "DBSIZE", summaryZH: "读取 Key 数量", summaryEN: "Read the key count", isReadOnly: true),
        .init(name: "MGET", syntax: "MGET key [key ...]", summaryZH: "读取多个字符串值", summaryEN: "Read multiple string values", isReadOnly: true, arguments: [.key()], repeatingArgumentStartIndex: 0, compatibleKeyTypes: [.string]),
        .init(name: "INCR", syntax: "INCR key", summaryZH: "递增整数值", summaryEN: "Increment an integer value", isReadOnly: false, arguments: [.key()], compatibleKeyTypes: [.string]),
        .init(name: "LRANGE", syntax: "LRANGE key start stop", summaryZH: "读取列表范围", summaryEN: "Read a list range", isReadOnly: true, arguments: [.key(), .integer("start"), .integer("stop")], compatibleKeyTypes: [.list]),
        .init(name: "LPUSH", syntax: "LPUSH key element [element ...]", summaryZH: "从左侧写入列表", summaryEN: "Push elements to a list", isReadOnly: false, arguments: [.key(), .value("element")], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.list]),
        .init(name: "SMEMBERS", syntax: "SMEMBERS key", summaryZH: "读取集合成员", summaryEN: "Read set members", isReadOnly: true, arguments: [.key()], compatibleKeyTypes: [.set]),
        .init(name: "SADD", syntax: "SADD key member [member ...]", summaryZH: "添加集合成员", summaryEN: "Add set members", isReadOnly: false, arguments: [.key(), .value("member")], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.set]),
        .init(name: "SREM", syntax: "SREM key member [member ...]", summaryZH: "删除集合成员", summaryEN: "Remove set members", isReadOnly: false, arguments: [.key(), .value("member")], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.set]),
        .init(name: "SISMEMBER", syntax: "SISMEMBER key member", summaryZH: "检查集合成员", summaryEN: "Check a set member", isReadOnly: true, arguments: [.key(), .value("member")], compatibleKeyTypes: [.set]),
        .init(name: "HGET", syntax: "HGET key field", summaryZH: "读取哈希字段", summaryEN: "Read a hash field", isReadOnly: true, arguments: [.key(), .field()], compatibleKeyTypes: [.hash]),
        .init(name: "HGETALL", syntax: "HGETALL key", summaryZH: "读取全部哈希字段", summaryEN: "Read all hash fields", isReadOnly: true, arguments: [.key()], compatibleKeyTypes: [.hash]),
        .init(name: "HSET", syntax: "HSET key field value [field value ...]", summaryZH: "设置哈希字段", summaryEN: "Set hash fields", isReadOnly: false, arguments: [.key(), .field(), .value()], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.hash]),
        .init(name: "HDEL", syntax: "HDEL key field [field ...]", summaryZH: "删除哈希字段", summaryEN: "Delete hash fields", isReadOnly: false, arguments: [.key(), .field()], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.hash]),
        .init(name: "HEXISTS", syntax: "HEXISTS key field", summaryZH: "检查哈希字段", summaryEN: "Check a hash field", isReadOnly: true, arguments: [.key(), .field()], compatibleKeyTypes: [.hash]),
        .init(name: "ZRANGE", syntax: "ZRANGE key start stop [WITHSCORES]", summaryZH: "读取有序集合范围", summaryEN: "Read a sorted-set range", isReadOnly: true, arguments: [.key(), .integer("start"), .integer("stop"), .keyword("WITHSCORES", values: ["WITHSCORES"])], compatibleKeyTypes: [.sortedSet]),
        .init(name: "ZADD", syntax: "ZADD key score member [score member ...]", summaryZH: "添加有序集合成员", summaryEN: "Add sorted-set members", isReadOnly: false, arguments: [.key(), .other("score", descriptionZH: "成员分值", descriptionEN: "Member score"), .value("member")], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.sortedSet]),
        .init(name: "ZREM", syntax: "ZREM key member [member ...]", summaryZH: "删除有序集合成员", summaryEN: "Remove sorted-set members", isReadOnly: false, arguments: [.key(), .value("member")], repeatingArgumentStartIndex: 1, compatibleKeyTypes: [.sortedSet]),
        .init(name: "ZSCORE", syntax: "ZSCORE key member", summaryZH: "读取有序集合成员分值", summaryEN: "Read a sorted-set member score", isReadOnly: true, arguments: [.key(), .value("member")], compatibleKeyTypes: [.sortedSet]),
        .init(name: "XRANGE", syntax: "XRANGE key start end [COUNT count]", summaryZH: "读取 Stream 范围", summaryEN: "Read a stream range", isReadOnly: true, arguments: [.key(), .other("start", descriptionZH: "起始 Stream ID", descriptionEN: "Starting stream ID"), .other("end", descriptionZH: "结束 Stream ID", descriptionEN: "Ending stream ID"), .keyword("COUNT", values: ["COUNT"]), .integer("count", optional: true)], compatibleKeyTypes: [.stream]),
        .init(name: "XADD", syntax: "XADD key id field value [field value ...]", summaryZH: "写入 Stream", summaryEN: "Append to a stream", isReadOnly: false, arguments: [.key(), .other("id", descriptionZH: "Stream ID，自动生成时使用 *", descriptionEN: "Stream ID; use * for an automatic ID"), .field(), .value()], repeatingArgumentStartIndex: 2, compatibleKeyTypes: [.stream]),
        .init(name: "INFO", syntax: "INFO [section]", summaryZH: "读取服务器信息", summaryEN: "Read server information", isReadOnly: true, arguments: [.other("section", descriptionZH: "可选的信息分区", descriptionEN: "Optional information section", optional: true)]),
        .init(name: "PING", syntax: "PING [message]", summaryZH: "检查连接", summaryEN: "Check the connection", isReadOnly: true, arguments: [.value("message", optional: true)]),
    ]

    static func matching(_ source: String) -> [RedisCommandCatalogEntry] {
        let token = source.split(whereSeparator: { $0.isWhitespace }).first
            .map(String.init)?.uppercased() ?? ""
        guard !token.isEmpty else { return Array(entries.prefix(8)) }
        return entries.filter { $0.name.hasPrefix(token) }
    }

    static func entry(named name: String?) -> RedisCommandCatalogEntry? {
        guard let name else { return nil }
        return entries.first { $0.name == name.uppercased() }
    }
}

actor RedisCommandParser {
    func parse(_ source: String) throws -> RedisCommandInvocation {
        let tokenization = RedisCommandTokenizer.tokenize(source)
        guard !tokenization.hasUnterminatedQuote else {
            throw RedisCommandParseError.unterminatedQuote
        }
        let arguments = tokenization.arguments
        guard !arguments.isEmpty else { throw RedisCommandParseError.empty }
        return RedisCommandInvocation(source: source, arguments: arguments)
    }
}

enum RedisCommandParseError: LocalizedError {
    case empty
    case unterminatedQuote

    var errorDescription: String? {
        switch self {
        case .empty:
            AppCopy.current.text("请输入 Redis 命令。", "Enter a Redis command.")
        case .unterminatedQuote:
            AppCopy.current.text("命令中有未闭合的引号。", "The command contains an unterminated quote.")
        }
    }
}
