import Foundation

struct RedisCommandTranscriptEntry: Equatable, Identifiable, Sendable {
    enum Outcome: Equatable, Sendable {
        case executing
        case success(reply: RedisReplyValue, elapsedSeconds: Double)
        case failure(String)
        case cancelled
    }

    let id: UUID
    let databaseIndex: Int
    let command: String
    var outcome: Outcome
}
