import Foundation
import QueryCraftFeature

indirect enum RedisRawReplyValue: Sendable {
    case status(String)
    case blob(Data)
    case error(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case array([RedisRawReplyValue])
    case map([(RedisRawReplyValue, RedisRawReplyValue)])
    case set([RedisRawReplyValue])
    case null

    var dataValue: Data? {
        switch self {
        case let .blob(data): data
        case let .status(value): Data(value.utf8)
        case let .integer(value): Data(String(value).utf8)
        case let .double(value): Data(String(value).utf8)
        case let .boolean(value): Data((value ? "1" : "0").utf8)
        case .array, .map, .set, .null, .error: nil
        }
    }

    var stringValue: String? {
        dataValue.map { String(decoding: $0, as: UTF8.self) }
    }

    var integerValue: Int64? {
        switch self {
        case let .integer(value): value
        default: stringValue.flatMap(Int64.init)
        }
    }

    var collectionValues: [RedisRawReplyValue]? {
        switch self {
        case let .array(values), let .set(values): values
        case .status, .blob, .error, .integer, .double, .boolean, .map, .null:
            nil
        }
    }

    var redisReplyValue: RedisReplyValue {
        switch self {
        case let .status(value): .simpleString(value)
        case let .blob(data):
            .bulkString(String(decoding: data, as: UTF8.self))
        case let .error(value): .error(value)
        case let .integer(value): .integer(value)
        case let .double(value): .double(value)
        case let .boolean(value): .boolean(value)
        case let .array(values):
            .array(values.map(\.redisReplyValue))
        case let .map(entries):
            .map(entries.map {
                RedisReplyMapEntry(
                    key: $0.0.redisReplyValue,
                    value: $0.1.redisReplyValue
                )
            })
        case let .set(values):
            .set(values.map(\.redisReplyValue))
        case .null: .null
        }
    }
}
