public struct RedisCommandResult: Equatable, Sendable {
    public let invocation: RedisCommandInvocation
    public let reply: RedisReplyValue
    public let elapsedSeconds: Double

    public init(
        invocation: RedisCommandInvocation,
        reply: RedisReplyValue,
        elapsedSeconds: Double
    ) {
        self.invocation = invocation
        self.reply = reply
        self.elapsedSeconds = elapsedSeconds
    }
}
