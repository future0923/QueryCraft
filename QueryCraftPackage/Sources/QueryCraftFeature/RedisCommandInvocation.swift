public struct RedisCommandInvocation: Equatable, Sendable {
    public let source: String
    public let arguments: [String]

    public init(source: String, arguments: [String]) {
        self.source = source
        self.arguments = arguments
    }

    public var name: String? { arguments.first?.uppercased() }
}
