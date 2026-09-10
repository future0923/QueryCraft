import Foundation

struct RedisClientError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}
