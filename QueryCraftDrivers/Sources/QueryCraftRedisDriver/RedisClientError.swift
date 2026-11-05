import Foundation

struct RedisClientError: LocalizedError, CustomNSError, Equatable, Sendable {
    let message: String
    var transportCode: Int? = nil

    static var errorDomain: String { "io.querycraft.driver.redis" }
    var errorCode: Int { transportCode ?? 0 }
    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let token = message.split(separator: " ", maxSplits: 1).first {
            info["response_code"] = String(token)
        }
        return info
    }

    var errorDescription: String? { message }
}
