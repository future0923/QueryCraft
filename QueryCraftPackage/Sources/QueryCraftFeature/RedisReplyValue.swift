public indirect enum RedisReplyValue: Equatable, Sendable {
    case simpleString(String)
    case bulkString(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case array([RedisReplyValue])
    case map([RedisReplyMapEntry])
    case set([RedisReplyValue])
    case null
    case error(String)
}
