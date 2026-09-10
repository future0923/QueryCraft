import Foundation

public struct RedisBinaryCommandInvocation: Equatable, Sendable {
    public let source: String
    public let arguments: [RedisBinaryValue]

    public init(source: String, arguments: [RedisBinaryValue]) {
        self.source = source
        self.arguments = arguments
    }

    public init(source: String, utf8Arguments: [String]) {
        self.init(
            source: source,
            arguments: utf8Arguments.map(RedisBinaryValue.init(utf8:))
        )
    }
}
