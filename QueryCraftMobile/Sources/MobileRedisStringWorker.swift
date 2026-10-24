import Foundation
import QueryCraftMobileCore

actor MobileRedisStringWorker {
    func value(text: String, hex: Bool) throws -> RedisBinaryValue {
        if hex {
            guard let data = RedisHexCodec.parse(text) else { throw RedisKeyEditError.invalidHex }
            return .init(data: data)
        }
        return .init(utf8: text)
    }
    func presentation(value: RedisBinaryValue?, hex requested: Bool? = nil) throws -> (text: String, hex: Bool) {
        guard let value else { return ("", false) }
        let text = value.losslessUTF8String
        let hex = requested ?? (text == nil)
        guard hex || text != nil else { throw RedisKeyEditError.invalidHex }
        return (hex ? RedisHexCodec.format(value.data) : text ?? "", hex)
    }
}
